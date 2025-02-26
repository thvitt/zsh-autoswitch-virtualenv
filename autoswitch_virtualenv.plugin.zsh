export AUTOSWITCH_VERSION="3.1.1"
export AUTOSWITCH_FILE=".venv"
export AUTOSWITCH_DIR=".venv"

RED="\e[31m"
GREEN="\e[32m"
PURPLE="\e[35m"
BOLD="\e[1m"
NORMAL="\e[0m"


function _validated_source() {
    local target_path="$1"

    if [[ "$target_path" == *'..'* ]]; then
        (>&2 printf "AUTOSWITCH WARNING: ")
        (>&2 printf "target virtualenv contains invalid characters\n")
        (>&2 printf "virtualenv activation cancelled\n")
        return
    else
        source "$target_path"
    fi
}


function _virtual_env_dir() {
    local venv_name="$1"
    local VIRTUAL_ENV_DIR="${AUTOSWITCH_VIRTUAL_ENV_DIR:-$HOME/.virtualenvs}"
    mkdir -p "$VIRTUAL_ENV_DIR"
    printf "%s/%s" "$VIRTUAL_ENV_DIR" "$venv_name"
}


function _python_version() {
    local PYTHON_BIN="$1"
    if [[ -f "$PYTHON_BIN" ]] then
        # For some reason python --version writes to stderr
        printf "%s" "$($PYTHON_BIN --version 2>&1)"
    else
        printf "unknown"
    fi
}


function _autoswitch_message() {
    if [ -z "$AUTOSWITCH_SILENT" ]; then
        (>&2 printf "$@")
    fi
}


function _get_venv_type() {
    local venv_dir="$1"
    local venv_type="${2:-virtualenv}"
    if [[ -f "$venv_dir/Pipfile" ]]; then
        venv_type="pipenv"
    elif [[ -f "$venv_dir/poetry.lock" ]]; then
        venv_type="poetry"
    elif [[ -f "$venv_dir/environment.yml" ]]; then
        venv_type="conda"
    elif [[ -f "$venv_dir/requirements.txt" || -f "$venv_dir/setup.py" ]]; then
        venv_type="virtualenv"
    fi
    printf "%s" "$venv_type"
}


function _get_venv_name() {
    local venv_dir="$1"
    local venv_type="$2"
    local venv_name="$(basename "$venv_dir")"

    if [[ "$venv_name" = "$AUTOSWITCH_DIR" ]]; then
        venv_name="${venv_dir:h:t}"
    fi

    # clear pipenv from the extra identifiers at the end
    if [[ "$venv_type" == "pipenv" ]]; then
        venv_name="${venv_name%-*}"
    fi

    printf "%s" "$venv_name"
}


function _maybeworkon() {
    local venv_dir="$1"
    local venv_type="$2"
    local venv_name="$(_get_venv_name $venv_dir $venv_type)"

    local DEFAULT_MESSAGE_FORMAT="Switching %venv_type: ${BOLD}${PURPLE}%venv_name${NORMAL} ${GREEN}[🐍%py_version]${NORMAL}"
    if [[ "$LANG" != *".UTF-8" ]]; then
        # Remove multibyte characters if the terminal does not support utf-8
        DEFAULT_MESSAGE_FORMAT="${DEFAULT_MESSAGE_FORMAT/🐍/}"
    fi

    # Don't reactivate an already activated virtual environment
    if [[ -z "$VIRTUAL_ENV" || "$venv_name" != "$(_get_venv_name $VIRTUAL_ENV $venv_type)" ]]; then

        if [[ ! -d "$venv_dir" ]]; then
            printf "Unable to find ${PURPLE}$venv_name${NORMAL} virtualenv\n"
            printf "If the issue persists run ${PURPLE}rmvenv && mkvenv${NORMAL} in this directory\n"
            return
        fi

        _deactivate_all

        local py_version="$(_python_version "$venv_dir/bin/python")"
        local message="${AUTOSWITCH_MESSAGE_FORMAT:-"$DEFAULT_MESSAGE_FORMAT"}"
        message="${message//\%venv_type/$venv_type}"
        message="${message//\%venv_name/$venv_name}"
        message="${message//\%py_version/$py_version}"
        _autoswitch_message "${message}\n"

        # If we are using pipenv and activate its virtual environment - turn down its verbosity
        # to prevent users seeing " Pipenv found itself running within a virtual environment" warning
        if [[ "$venv_type" == "pipenv" && "$PIPENV_VERBOSITY" != -1 ]]; then
            export PIPENV_VERBOSITY=-1
        fi

        # Much faster to source the activate file directly rather than use the `workon` command
        local activate_script="$venv_dir/bin/activate"

        _validated_source "$activate_script"
    fi
}


# Gives the path to the nearest target file
function _check_path()
{
    local check_dir="$1"

    if [[ "${check_dir}" = "${AUTOSWITCH_CURRENT_VENV_PATH:h}" ]]; then
        printf "*"
        return
    elif [[ -f "${check_dir}/${AUTOSWITCH_FILE}" ]]; then
        printf "${check_dir}/${AUTOSWITCH_FILE}"
        return
    elif [[ -d "${check_dir}/${AUTOSWITCH_DIR}" ]]; then
        printf "${check_dir}/${AUTOSWITCH_DIR}"
        return
    elif [[ -f "${check_dir}/poetry.lock" ]]; then
        printf "${check_dir}/poetry.lock"
    elif [[ -f "${check_dir}/Pipfile" ]]; then
        printf "${check_dir}/Pipfile"
    elif [[ -f "${check_dir}/environment.yml" ]]; then
        printf "${check_dir}/environment.yml"
    else
        # Abort search at file system root or HOME directory (latter is a performance optimisation).
        if [[ "$check_dir" = "/" || "$check_dir" = "$HOME" ]]; then
            return
        fi
        _check_path "$(dirname "$check_dir")"
    fi
}


function _activate_poetry() {
    # check if any environments exist before trying to activate
    # if env list is empty, then no environment exists that can be activated
    local name="$(poetry env list --full-path | sort -k 2 | tail -n 1 | cut -d' ' -f1)"
    if [[ -n "$name" ]]; then
        _maybeworkon "$name" "poetry"
        return 0
    fi
    return 1
}


function _activate_pipenv() {
    # unfortunately running pipenv each time we are in a pipenv project directory is slow :(
    if venv_path="$(PIPENV_IGNORE_VIRTUALENVS=1 pipenv --venv 2>/dev/null)"; then
        _maybeworkon "$venv_path" "pipenv"
        return 0
    fi
    return 1
}

function _deactivate_all() {
    if (( $+functions[deactivate] )) && [[ -n "$VIRTUAL_ENV" ]]; then
        deactivate
    fi

    if (( $+functions[conda] )) && [[ -n "$CONDA_DEFAULT_ENV" ]]; then
        conda deactivate
    fi
}

function _activate_conda() {

    if (( $+functions[conda] )); then
        _deactivate_all
        if conda activate "$1"; then
            return 0
        fi
    else
    fi
    return 1
}

# Automatically switch virtualenv when $AUTOSWITCH_FILE file detected
function check_venv()
{
    local file_owner
    local file_permissions

    # Get the $AUTOSWITCH_FILE, scanning parent directories
    local venv_path="$(_check_path "$PWD")"

    if [[ -n "$venv_path" ]]; then

        if [[ "$venv_path" = "*" ]]; then
            # current env, we’re just staying here
            return
        fi

        /usr/bin/stat --version &> /dev/null
        if [[ $? -eq 0 ]]; then   # Linux, or GNU stat
            file_owner="$(/usr/bin/stat -c %u "$venv_path")"
            file_permissions="$(/usr/bin/stat -c %a "$venv_path")"
        else                      # macOS, or FreeBSD stat
            file_owner="$(/usr/bin/stat -f %u "$venv_path")"
            file_permissions="$(/usr/bin/stat -f %OLp "$venv_path")"
        fi

        if [[ "$file_owner" != "$(id -u)" ]]; then
            printf "AUTOSWITCH WARNING: Virtualenv will not be activated\n\n"
            printf "Reason: Found a $AUTOSWITCH_FILE file but it is not owned by the current user\n"
            printf "Change ownership of ${PURPLE}$venv_path${NORMAL} to ${PURPLE}'$USER'${NORMAL} to fix this\n"
        elif ! [[ "$file_permissions" =~ ^[764][045][045]$ ]]; then
            printf "AUTOSWITCH WARNING: Virtualenv will not be activated\n\n"
            printf "Reason: Found a $AUTOSWITCH_FILE file with weak permission settings ($file_permissions).\n"
            printf "Run the following command to fix this: ${PURPLE}\"chmod 600 $venv_path\"${NORMAL}\n"
        else
            AUTOSWITCH_CURRENT_VENV_PATH="$venv_path"
            if [[ -d "$venv_path" ]]; then
                if _maybeworkon "$venv_path" virtualenv; then
                    return
                fi
            fi
            if [[ "$venv_path" == *"/Pipfile" ]] && type "pipenv" > /dev/null; then
                if _activate_pipenv; then
                    return
                fi
            elif [[ "$venv_path" == *"/poetry.lock" ]] && type "poetry" > /dev/null; then
                if _activate_poetry; then
                    return
                fi
            elif [[ "$venv_path" == *"/environment.yml" ]] && type "conda" > /dev/null; then
                local switch_to="$(awk '/^name:/ {print $2}' "$venv_path")"
                if _activate_conda "$switch_to"
                then
                    return
                else
                    echo "Found conda environment spec for ${PURPLE}$switch_to${NORMAL} in ${PURPLE}$venv_path${NORMAL}."
                    echo "Run ${GREEN}mkvenv${NORMAL} to create that environment."
                fi
            else
                local switch_to="$(<"$venv_path")"
                if _activate_conda "$switch_to"
                then
                    return
                fi
                local virtual_env_dir="$(_virtual_env_dir "$switch_to")"
                _maybeworkon "$virtual_env_dir" "virtualenv"
                return
            fi
            # if we got here, setting the path has not worked
            unset AUTOSWITCH_CURRENT_VENV_PATH
        fi
    fi

    local venv_type="$(_get_venv_type "$PWD" "unknown")"

    # If we still haven't got anywhere, fallback to defaults
    if [[ "$venv_type" != "unknown" ]]; then
        printf "Python ${PURPLE}$venv_type${NORMAL} project detected. "
        printf "Run ${PURPLE}mkvenv${NORMAL} to setup autoswitching\n"
    fi
    _default_venv
}


# Switch to the default virtual environment
function _default_venv()
{
    local venv_type="$(_get_venv_type "$OLDPWD")"
    if [[ -n "$AUTOSWITCH_DEFAULTENV" ]]; then
        _maybeworkon "$(_virtual_env_dir "$AUTOSWITCH_DEFAULTENV")" "$venv_type"
    elif [[ -n "$VIRTUAL_ENV" ]]; then
        local venv_name="$(_get_venv_name "$VIRTUAL_ENV" "$venv_type")"
        _autoswitch_message "Deactivating: ${BOLD}${PURPLE}%s${NORMAL}\n" "$venv_name"
        unset AUTOSWITCH_CURRENT_VENV_PATH
        deactivate
    elif (( $+functions[conda] )) && [[ -n "$CONDA_DEFAULT_ENV" ]]; then
        _autoswitch_message "Deactivating conda env: ${BOLD}${PURPLE}%s${NORMAL}\n" "$CONDA_DEFAULT_ENV"
        unset AUTOSWITCH_CURRENT_VENV_PATH
        conda deactivate
    fi
}


# remove project environment for current directory
function rmvenv()
{
    local venv_type="$(_get_venv_type "$PWD" "unknown")"

    if [[ "$venv_type" == "pipenv" ]]; then
        deactivate
        pipenv --rm
    elif [[ "$venv_type" == "poetry" ]]; then
        deactivate
        poetry env remove "$(poetry run which python)"
    else
        if [[ -f "$AUTOSWITCH_FILE" ]]; then
            local venv_name="$(<$AUTOSWITCH_FILE)"

            # detect if we need to switch virtualenv first
            if [[ -n "$VIRTUAL_ENV" ]]; then
                local current_venv="$(basename $VIRTUAL_ENV)"
                if [[ "$current_venv" = "$venv_name" ]]; then
                    _default_venv
                fi
            fi

            printf "Removing ${PURPLE}%s${NORMAL}...\n" "$venv_name"
            # Using explicit paths to avoid any alias/function interference.
            # rm should always be found in this location according to
            # https://refspecs.linuxfoundation.org/FHS_3.0/fhs/ch03s04.html
            # https://www.freedesktop.org/wiki/Software/systemd/TheCaseForTheUsrMerge/
            /bin/rm -rf "$(_virtual_env_dir "$venv_name")"
            /bin/rm "$AUTOSWITCH_FILE"
        else
            printf "No $AUTOSWITCH_FILE file in the current directory!\n"
        fi
    fi
}


function _missing_error_message() {
    local command="$1"
    printf "${BOLD}${RED}"
    printf "zsh-autoswitch-virtualenv requires '%s' to install this project!\n\n" "$command"
    printf "${NORMAL}"
    printf "If this is already installed but you are still seeing this message, \n"
    printf "then make sure the ${BOLD}$command${NORMAL} command is in your PATH.\n" $command
    printf "\n"
}


# helper function to create a project environment for the current directory
function mkvenv()
{
    local venv_type="$(_get_venv_type "$PWD" "unknown")"
    # Copy parameters variable so that we can mutate it
    # NOTE: Keep declaration of variable and assignment separate for zsh 5.0 compatibility
    local params
    params=("${@[@]}")

    if [[ "$venv_type" == "pipenv" ]]; then
        if ! type "pipenv" > /dev/null; then
            _missing_error_message pipenv
            return
        fi
        # TODO: detect if this is already installed
        pipenv install --dev $params
        _activate_pipenv
        return
    elif [[ "$venv_type" == "poetry" ]]; then
        if ! type "poetry" > /dev/null; then
            _missing_error_message poetry
            return
        fi
        # TODO: detect if this is already installed
        poetry install $params
        _activate_poetry
        return
    elif [[ "$venv_type" == "conda" ]]; then
        conda env create
        local switch_to="$(awk '/^name:/ {print $2}' "environment.yml")"
        _activate_conda "$switch_to"
    else
        if ! type "virtualenv" > /dev/null; then
            _missing_error_message virtualenv
            return
        fi

        if [[ -f "$AUTOSWITCH_FILE" ]]; then
            printf "$AUTOSWITCH_FILE file already exists. If this is a mistake use the rmvenv command\n"
        else
            local venv_name="$(basename $PWD)"

            printf "Creating ${PURPLE}%s${NONE} virtualenv\n" "$venv_name"


            if [[ -n "$AUTOSWITCH_DEFAULT_PYTHON" && ${params[(I)--python*]} -eq 0 ]]; then
                params+="--python=$AUTOSWITCH_DEFAULT_PYTHON"
            fi

            if [[ ${params[(I)--verbose]} -eq 0 ]]; then
                virtualenv $params "$(_virtual_env_dir "$venv_name")"
            else
                virtualenv $params "$(_virtual_env_dir "$venv_name")" > /dev/null
            fi

            printf "$venv_name\n" > "$AUTOSWITCH_FILE"
            chmod 600 "$AUTOSWITCH_FILE"

            _maybeworkon "$(_virtual_env_dir "$venv_name")" "virtualenv"

            install_requirements
        fi
    fi
}


function install_requirements() {
    if [[ -f "$AUTOSWITCH_DEFAULT_REQUIREMENTS" ]]; then
        printf "Install default requirements? (${PURPLE}$AUTOSWITCH_DEFAULT_REQUIREMENTS${NORMAL}) [y/N]: "
        read ans

        if [[ "$ans" = "y" || "$ans" == "Y" ]]; then
            pip install -r "$AUTOSWITCH_DEFAULT_REQUIREMENTS"
        fi
    fi

    if [[ -f "$PWD/setup.py" ]]; then
        printf "Found a ${PURPLE}setup.py${NORMAL} file. Install dependencies? [y/N]: "
        read ans

        if [[ "$ans" = "y" || "$ans" = "Y" ]]; then
            if [[ "$AUTOSWITCH_PIPINSTALL" = "FULL" ]]
            then
                pip install .
            else
                pip install -e .
            fi
        fi
    fi

    setopt nullglob
    local requirements
    for requirements in **/*requirements.txt
    do
        printf "Found a ${PURPLE}%s${NORMAL} file. Install? [y/N]: " "$requirements"
        read ans

        if [[ "$ans" = "y" || "$ans" = "Y" ]]; then
            pip install -r "$requirements"
        fi
    done
}


function enable_autoswitch_virtualenv() {
    autoload -Uz add-zsh-hook
    disable_autoswitch_virtualenv
    add-zsh-hook chpwd check_venv
}


function disable_autoswitch_virtualenv() {
    add-zsh-hook -D chpwd check_venv
}


enable_autoswitch_virtualenv
check_venv
