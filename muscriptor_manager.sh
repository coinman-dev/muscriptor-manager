#!/usr/bin/env bash
# MuScriptor Manager for Linux
set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
MODEL=large
DEVICE=auto
TORCH_BACKEND=auto
PORT=8222
BIND_ADDRESS=127.0.0.1
START_BACKGROUND=false
RESTART=false
ACTION=run
DIRECTORY=
TOKEN=
SAVE_TOKEN=false
CLEAR_SAVED_TOKEN=false
FORCE_DOWNLOAD=false
NON_INTERACTIVE=false

MODEL_NAMES=(small medium large)
CONFIG_DIRECTORY="${XDG_CONFIG_HOME:-$HOME/.config}/muscriptor-manager"
TOKEN_FILE="$CONFIG_DIRECTORY/hf_token"
PATH_FILE="$CONFIG_DIRECTORY/path.sh"
INSTALLATION_FILE="$CONFIG_DIRECTORY/installation.sh"
BASHRC_FILE="$HOME/.bashrc"

color() {
    local code=$1
    shift
    if [[ -t 1 ]]; then
        printf '\033[%sm%s\033[0m\n' "$code" "$*"
    else
        printf '%s\n' "$*"
    fi
}

step() { printf '\n'; color '36' "== $* =="; }
info() { color '32' "$*"; }
warn() { color '33' "Warning: $*" >&2; }
die() { color '31' "Error: $*" >&2; exit 1; }

on_error() {
    local status=$?
    printf 'Error: command failed (exit code %s): %s\n' "$status" "$BASH_COMMAND" >&2
    exit "$status"
}
trap on_error ERR

show_help() {
    cat <<EOF
MuScriptor Manager for Linux

Usage: ./$SCRIPT_NAME [options]

Run options:
  --model small|medium|large       Model to run (default: large)
  --device auto|cpu|cuda           Inference device (default: auto)
  --torch-backend auto|cpu|cu118|cu121|cu124|cu126|cu128|cu130
                                     PyTorch build for installation (default: auto)
  --port NUMBER                    Web UI port (default: 8222)
  --bind-address ADDRESS           Bind address (default: 127.0.0.1)
  --start                          Start in the background
  --restart                        Restart in the background
  --stop                           Stop the managed server
  --status                         Show server, environment, and model status

Installation and model options:
  --install                        Install or repair the environment, then exit
  --update                         Upgrade MuScriptor and the selected PyTorch build
  --download                       Download the selected model, then exit
  --download-all                   Download small, medium, and large models
  --force-download                 Re-download files with --download/--download-all
  --list-models                    Show cached model variants
  --gpu-info                       Show GPU, driver, and recommended PyTorch build
  --directory PATH                 Environment and model-cache directory
  --token hf_...                   Hugging Face token for this run
  --save-token                     Save token in a mode-600 user config file
  --non-interactive                Never prompt; fail if a token is required

Maintenance options:
  --uninstall                      Remove environment, model cache, logs, and PATH entry
  --clear-saved-token              Also remove the saved Hugging Face token (with --uninstall)
  --help                           Show this help

Examples:
  ./$SCRIPT_NAME
  ./$SCRIPT_NAME --model medium --start
  ./$SCRIPT_NAME --gpu-info
  ./$SCRIPT_NAME --download-all
  ./$SCRIPT_NAME --directory /mnt/models/muscriptor --model large
EOF
}

require_value() {
    local option=$1
    [[ $# -ge 2 && -n ${2:-} ]] || die "$option requires a value."
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --model|-m)
                require_value "$1" "${2:-}"; MODEL=$2; shift 2 ;;
            --device)
                require_value "$1" "${2:-}"; DEVICE=$2; shift 2 ;;
            --torch-backend)
                require_value "$1" "${2:-}"; TORCH_BACKEND=$2; shift 2 ;;
            --port|-p)
                require_value "$1" "${2:-}"; PORT=$2; shift 2 ;;
            --bind-address)
                require_value "$1" "${2:-}"; BIND_ADDRESS=$2; shift 2 ;;
            --directory|-d)
                require_value "$1" "${2:-}"; DIRECTORY=$2; shift 2 ;;
            --token|-t)
                require_value "$1" "${2:-}"; TOKEN=$2; shift 2 ;;
            --install|--update|--download|--download-all|--list-models|--gpu-info|--stop|--status|--uninstall)
                [[ $ACTION == run ]] || die 'Choose only one action.'
                ACTION=${1#--}; shift ;;
            --start) START_BACKGROUND=true; shift ;;
            --restart) RESTART=true; shift ;;
            --force-download) FORCE_DOWNLOAD=true; shift ;;
            --save-token) SAVE_TOKEN=true; shift ;;
            --clear-saved-token) CLEAR_SAVED_TOKEN=true; shift ;;
            --non-interactive) NON_INTERACTIVE=true; shift ;;
            --help|-h) show_help; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    case $MODEL in small|medium|large) ;; *) die '--model must be small, medium, or large.' ;; esac
    case $DEVICE in auto|cpu|cuda) ;; *) die '--device must be auto, cpu, or cuda.' ;; esac
    case $TORCH_BACKEND in auto|cpu|cu118|cu121|cu124|cu126|cu128|cu130) ;; *) die 'Invalid --torch-backend value.' ;; esac
    [[ $PORT =~ ^[0-9]+$ && $PORT -ge 1 && $PORT -le 65535 ]] || die '--port must be between 1 and 65535.'
    if [[ $ACTION != run && ( $START_BACKGROUND == true || $RESTART == true ) ]]; then
        die '--start and --restart cannot be combined with an action.'
    fi
    if [[ $START_BACKGROUND == true && $RESTART == true ]]; then
        die 'Choose either --start or --restart.'
    fi
    if [[ $FORCE_DOWNLOAD != false && $ACTION != download && $ACTION != download-all ]]; then
        die '--force-download can only be used with --download or --download-all.'
    fi
    if [[ $CLEAR_SAVED_TOKEN != false && $ACTION != uninstall ]]; then
        die '--clear-saved-token can only be used with --uninstall.'
    fi
}

set_manager_paths() {
    DIRECTORY=${1%/}
    [[ -n $DIRECTORY ]] || die 'Installation directory cannot be empty.'
    ENV_PATH="$DIRECTORY/muscriptor_env"
    CACHE_PATH="$DIRECTORY/HuggingFaceCache"
    LOG_PATH="$DIRECTORY/logs"
    PID_FILE="$DIRECTORY/muscriptor.pid"
    STATE_FILE="$DIRECTORY/muscriptor.state"
    PYTHON_EXE="$ENV_PATH/bin/python"
    MUSCRIPTOR_EXE="$ENV_PATH/bin/muscriptor"
    STDOUT_LOG="$LOG_PATH/muscriptor.out.log"
    STDERR_LOG="$LOG_PATH/muscriptor.err.log"
}

default_installation_directory() {
    printf '%s\n' "${MUSCRIPTOR_HOME:-$HOME/.local/share/muscriptor}"
}

environment_exists_at() {
    local candidate=${1%/}
    [[ -x "$candidate/muscriptor_env/bin/python" && -x "$candidate/muscriptor_env/bin/muscriptor" ]]
}

load_registered_installation() {
    if [[ -r $INSTALLATION_FILE ]]; then
        # shellcheck disable=SC1090 # The manager creates this private config file.
        . "$INSTALLATION_FILE"
    fi
}

find_registered_installation() {
    load_registered_installation
    if [[ -n ${Muscriptor:-} ]] && environment_exists_at "$Muscriptor"; then
        printf '%s\n' "$Muscriptor"
        return 0
    fi
    return 1
}

resolve_installation_directory() {
    if [[ -n $DIRECTORY ]]; then
        set_manager_paths "$DIRECTORY"
        return
    fi

    local existing default_directory selected
    if existing=$(find_registered_installation); then
        set_manager_paths "$existing"
        info "Existing installation detected: $DIRECTORY (registered in Muscriptor)."
        return
    fi

    default_directory=$(default_installation_directory)
    set_manager_paths "$default_directory"
    if [[ $ACTION == status || $ACTION == stop || $ACTION == uninstall || $ACTION == list-models || $ACTION == gpu-info ]]; then
        return
    fi
    if [[ $NON_INTERACTIVE == true ]]; then
        warn "Installation directory was not specified. Using: $DIRECTORY"
        return
    fi
    if [[ ! -t 0 ]]; then
        die "No installation was found. Specify --directory or use --non-interactive."
    fi

    read -r -p "Installation directory [$default_directory]: " selected
    set_manager_paths "${selected:-$default_directory}"
    info "Installation directory: $DIRECTORY"
}

initialize_manager_directory() {
    mkdir -p "$DIRECTORY" "$CACHE_PATH"
    export HF_HOME="$CACHE_PATH"
    export HF_HUB_DISABLE_TELEMETRY=1
    export PYTHONUTF8=1
    export PYTHONIOENCODING=utf-8
}

register_installation_directory() {
    mkdir -p "$CONFIG_DIRECTORY"
    chmod 700 "$CONFIG_DIRECTORY"
    printf 'Managed by MuScriptor Manager.\n' > "$DIRECTORY/.muscriptor-manager"
    printf 'export Muscriptor=%q\n' "$DIRECTORY" > "$INSTALLATION_FILE"
    chmod 600 "$INSTALLATION_FILE"
    export Muscriptor="$DIRECTORY"
    info "Registered Muscriptor=$DIRECTORY"
}

unregister_installation_directory() {
    load_registered_installation
    if [[ ${Muscriptor:-} == "$DIRECTORY" ]]; then
        rm -f "$INSTALLATION_FILE"
        unset Muscriptor
        info 'Removed Muscriptor registration.'
    fi
}

add_to_user_path() {
    local bin_path="$ENV_PATH/bin"
    mkdir -p "$CONFIG_DIRECTORY"
    chmod 700 "$CONFIG_DIRECTORY"
    # shellcheck disable=SC2016 # Keep $PATH for shells that source this file later.
    printf 'export PATH=%q:"$PATH"\n' "$bin_path" > "$PATH_FILE"
    chmod 600 "$PATH_FILE"

    if [[ ! -f $BASHRC_FILE ]] || ! grep -Fq '# >>> muscriptor-manager >>>' "$BASHRC_FILE"; then
        cat >> "$BASHRC_FILE" <<EOF
# >>> muscriptor-manager >>>
[ -f "$INSTALLATION_FILE" ] && . "$INSTALLATION_FILE"
[ -f "$PATH_FILE" ] && . "$PATH_FILE"
# <<< muscriptor-manager <<<
EOF
        info "Added MuScriptor environment to PATH through $BASHRC_FILE"
    fi

    case ":$PATH:" in *":$bin_path:"*) ;; *) export PATH="$bin_path:$PATH" ;; esac
}

remove_from_user_path() {
    rm -f "$PATH_FILE"
    if [[ -f $BASHRC_FILE ]]; then
        sed -i '/# >>> muscriptor-manager >>>/,/# <<< muscriptor-manager <<</d' "$BASHRC_FILE"
    fi
    local bin_path="$ENV_PATH/bin"
    PATH=$(printf '%s' "$PATH" | awk -v target="$bin_path" -F: '{ for (i = 1; i <= NF; i++) { if ($i != target && $i != "") { printf "%s%s", separator, $i; separator=":" } } }')
    export PATH
}

can_remove_installation_root() {
    [[ -d $DIRECTORY ]] || return 1
    local resolved_directory item_name has_managed_item=false
    resolved_directory=$(readlink -f "$DIRECTORY")
    [[ $resolved_directory != / ]] || return 1

    while IFS= read -r item_name; do
        case $item_name in
            muscriptor_env|HuggingFaceCache|logs|muscriptor.pid|muscriptor.state|.muscriptor-manager)
                has_managed_item=true ;;
            *) return 1 ;;
        esac
    done < <(find "$DIRECTORY" -mindepth 1 -maxdepth 1 -printf '%f\n')
    [[ $has_managed_item == true ]]
}

find_uv() {
    if command -v uv >/dev/null 2>&1; then
        command -v uv
        return
    fi
    if [[ -x $HOME/.local/bin/uv ]]; then
        printf '%s\n' "$HOME/.local/bin/uv"
        return
    fi
    return 1
}

install_uv() {
    command -v curl >/dev/null 2>&1 || die 'curl is required to install uv automatically.'
    step 'Installing uv'
    curl --fail --location --proto '=https' --tlsv1.2 https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    find_uv || die 'uv installation completed, but uv was not found. Open a new terminal and run the script again.'
}

get_uv() {
    find_uv || install_uv
}

environment_installed() {
    [[ -x $PYTHON_EXE && -x $MUSCRIPTOR_EXE ]]
}

muscriptor_version() {
    environment_installed || return 1
    "$PYTHON_EXE" -c 'import importlib.metadata; print(importlib.metadata.version("muscriptor"))' 2>/dev/null
}

version_at_least() {
    local actual=$1 minimum=$2
    [[ $actual == "$minimum" ]] || [[ $(printf '%s\n%s\n' "$minimum" "$actual" | sort -V | head -n 1) == "$minimum" ]]
}

read_gpu_info() {
    command -v nvidia-smi >/dev/null 2>&1 || return 1
    nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1
}

recommended_torch_backend() {
    GPU_NAME=
    GPU_DRIVER=
    GPU_CAPABILITY=
    GPU_MEMORY=
    RECOMMENDED_BACKEND=cpu
    REQUIRED_DRIVER=
    PREFERRED_BACKEND=cpu
    PREFERRED_DRIVER=
    DRIVER_UPGRADE_REQUIRED=false
    DRIVER_UPGRADE_RECOMMENDED=false

    local gpu_info candidate backend minimum_driver
    gpu_info=$(read_gpu_info || true)
    [[ -n $gpu_info ]] || return
    IFS=',' read -r GPU_NAME GPU_DRIVER GPU_CAPABILITY GPU_MEMORY <<< "$gpu_info"
    GPU_NAME=${GPU_NAME## } ; GPU_DRIVER=${GPU_DRIVER## }
    GPU_CAPABILITY=${GPU_CAPABILITY## } ; GPU_MEMORY=${GPU_MEMORY## }

    version_at_least "$GPU_CAPABILITY" 5.0 || return
    local -a candidates=()
    if version_at_least "$GPU_CAPABILITY" 10.0; then
        candidates=('cu130:580.65')
    elif version_at_least "$GPU_CAPABILITY" 7.5; then
        candidates=('cu130:580.65' 'cu126:560.28' 'cu124:550.54' 'cu121:525.60' 'cu118:450.80')
    else
        candidates=('cu126:560.28' 'cu124:550.54' 'cu121:525.60' 'cu118:450.80')
    fi

    PREFERRED_BACKEND=${candidates[0]%%:*}
    PREFERRED_DRIVER=${candidates[0]##*:}
    for candidate in "${candidates[@]}"; do
        backend=${candidate%%:*}
        minimum_driver=${candidate##*:}
        if version_at_least "$GPU_DRIVER" "$minimum_driver"; then
            RECOMMENDED_BACKEND=$backend
            REQUIRED_DRIVER=$minimum_driver
            [[ $backend == "$PREFERRED_BACKEND" ]] || DRIVER_UPGRADE_RECOMMENDED=true
            return
        fi
    done

    REQUIRED_DRIVER=$PREFERRED_DRIVER
    DRIVER_UPGRADE_REQUIRED=true
}

backend_driver_requirement() {
    case $1 in
        cu118) printf '450.80\n' ;;
        cu121) printf '525.60\n' ;;
        cu124) printf '550.54\n' ;;
        cu126) printf '560.28\n' ;;
        cu128) printf '570.65\n' ;;
        cu130) printf '580.65\n' ;;
        *) printf '0\n' ;;
    esac
}

resolve_torch_backend() {
    recommended_torch_backend
    EFFECTIVE_BACKEND=$RECOMMENDED_BACKEND
    if [[ $DEVICE == cpu || $TORCH_BACKEND == cpu ]]; then
        EFFECTIVE_BACKEND=cpu
        return
    fi
    if [[ $TORCH_BACKEND == auto ]]; then
        return
    fi
    [[ -n $GPU_CAPABILITY ]] || die "--torch-backend $TORCH_BACKEND requires an NVIDIA GPU detected by nvidia-smi."
    if version_at_least "$GPU_CAPABILITY" 10.0 && [[ $TORCH_BACKEND != cu130 ]]; then
        die "RTX 50xx/Blackwell requires --torch-backend cu130."
    fi
    local minimum_driver
    minimum_driver=$(backend_driver_requirement "$TORCH_BACKEND")
    version_at_least "$GPU_DRIVER" "$minimum_driver" || die "--torch-backend $TORCH_BACKEND requires NVIDIA driver $minimum_driver or newer; detected $GPU_DRIVER."
    EFFECTIVE_BACKEND=$TORCH_BACKEND
}

show_gpu_status() {
    resolve_torch_backend
    if [[ -z $GPU_NAME ]]; then
        warn 'NVIDIA GPU was not detected through nvidia-smi.'
        printf 'Recommended PyTorch backend: cpu\n'
        return
    fi
    printf 'NVIDIA GPU: %s | compute capability %s | %s MiB VRAM\n' "$GPU_NAME" "$GPU_CAPABILITY" "$GPU_MEMORY"
    printf 'NVIDIA driver: %s\n' "$GPU_DRIVER"
    printf 'Recommended PyTorch backend: %s\n' "$RECOMMENDED_BACKEND"
    if [[ $DRIVER_UPGRADE_REQUIRED == true ]]; then
        warn "Update the NVIDIA driver to $REQUIRED_DRIVER or newer, then run --update."
    elif [[ $DRIVER_UPGRADE_RECOMMENDED == true ]]; then
        warn "Current driver supports $RECOMMENDED_BACKEND. Update to $PREFERRED_DRIVER or newer for $PREFERRED_BACKEND."
    fi
}

ensure_environment() {
    local upgrade=${1:-false} version uv
    if version=$(muscriptor_version 2>/dev/null) && [[ $upgrade == false ]]; then
        register_installation_directory
        add_to_user_path
        info "Environment detected (MuScriptor $version)."
        return
    fi

    uv=$(get_uv)
    if [[ ! -x $PYTHON_EXE ]]; then
        step 'Creating Python environment'
        if [[ -d $ENV_PATH ]]; then
            "$uv" venv --clear --python 3.12 "$ENV_PATH"
        else
            "$uv" venv --python 3.12 "$ENV_PATH"
        fi
    fi

    step 'Installing MuScriptor'
    resolve_torch_backend
    printf 'Selected PyTorch backend: %s\n' "$EFFECTIVE_BACKEND"
    if [[ $DRIVER_UPGRADE_REQUIRED == true ]]; then
        warn 'NVIDIA driver is too old for a supported CUDA build. Installing the CPU build.'
    fi
    local -a arguments=(pip install --python "$PYTHON_EXE" --torch-backend "$EFFECTIVE_BACKEND")
    [[ $upgrade == true ]] && arguments+=(--upgrade)
    arguments+=('muscriptor>=0.2.1')
    "$uv" "${arguments[@]}"

    environment_installed || die 'Installation finished without creating the expected muscriptor executable.'
    "$PYTHON_EXE" -c 'import huggingface_hub, muscriptor, torch; print("torch=" + torch.__version__)'
    version=$(muscriptor_version)
    register_installation_directory
    add_to_user_path
    info "MuScriptor $version is ready."
}

get_model_state() {
    local name=$1 repository_cache reference revision snapshot
    MODEL_WEIGHTS=
    MODEL_SIZE=0
    repository_cache="$CACHE_PATH/hub/models--MuScriptor--muscriptor-$name"
    reference="$repository_cache/refs/main"
    if [[ -f $reference ]]; then
        revision=$(tr -d '[:space:]' < "$reference")
        if [[ $revision =~ ^[0-9a-fA-F]+$ ]] && [[ -s $repository_cache/snapshots/$revision/model.safetensors ]]; then
            MODEL_WEIGHTS="$repository_cache/snapshots/$revision/model.safetensors"
        fi
    fi
    if [[ -z $MODEL_WEIGHTS && -d $repository_cache/snapshots ]]; then
        snapshot=$(find "$repository_cache/snapshots" -type f -name model.safetensors ! -name '*.incomplete' -size +1024c -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2- || true)
        [[ -n $snapshot ]] && MODEL_WEIGHTS=$snapshot
    fi
    if [[ -n $MODEL_WEIGHTS && -s $MODEL_WEIGHTS && $(stat -c '%s' "$MODEL_WEIGHTS") -gt 1024 ]]; then
        MODEL_SIZE=$(stat -c '%s' "$MODEL_WEIGHTS")
    else
        MODEL_WEIGHTS=
    fi
}

show_model_status() {
    local name
    printf '%-8s %-16s %s\n' Model Status Size
    for name in "${MODEL_NAMES[@]}"; do
        get_model_state "$name"
        if [[ -n $MODEL_WEIGHTS ]]; then
            printf '%-8s %-16s %.2f GB\n' "$name" downloaded "$(awk "BEGIN {print $MODEL_SIZE / 1073741824}")"
        else
            printf '%-8s %-16s -\n' "$name" 'not downloaded'
        fi
    done
}

resolve_huggingface_token() {
    local hub_token
    if [[ -z $TOKEN ]]; then TOKEN=${HF_TOKEN:-}; fi
    if [[ -z $TOKEN && -r $TOKEN_FILE ]]; then TOKEN=$(<"$TOKEN_FILE"); fi
    if [[ -z $TOKEN && -x $PYTHON_EXE ]]; then
        hub_token=$("$PYTHON_EXE" -c 'from huggingface_hub import get_token; print(get_token() or "")' 2>/dev/null || true)
        TOKEN=${hub_token//$'\n'/}
    fi
    if [[ -z $TOKEN ]]; then
        [[ $NON_INTERACTIVE == false && -t 0 ]] || die 'HF_TOKEN is required to download a gated model in non-interactive mode.'
        warn 'The model is gated on Hugging Face. Accept its license, then enter a read token.'
        printf 'Token page: https://huggingface.co/settings/tokens\n'
        read -r -s -p 'HF_TOKEN: ' TOKEN
        printf '\n'
    fi
    [[ -n $TOKEN ]] || die 'A non-empty Hugging Face token is required to download MuScriptor models.'
    export HF_TOKEN="$TOKEN"
    if [[ $SAVE_TOKEN == true ]]; then
        mkdir -p "$CONFIG_DIRECTORY"
        chmod 700 "$CONFIG_DIRECTORY"
        printf '%s\n' "$TOKEN" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
        info "HF_TOKEN was saved in $TOKEN_FILE"
    fi
}

check_huggingface_model_access() {
    local repository=$1 status
    status=$(MUSCRIPTOR_ACCESS_REPOSITORY="$repository" "$PYTHON_EXE" - 2>/dev/null <<'PYTHON' || true
import os
from huggingface_hub import hf_hub_download
from huggingface_hub.errors import GatedRepoError, RepositoryNotFoundError

try:
    hf_hub_download(
        repo_id=os.environ["MUSCRIPTOR_ACCESS_REPOSITORY"],
        filename="config.json",
        token=os.environ.get("HF_TOKEN"),
    )
    print("ACCESS_GRANTED")
except (GatedRepoError, RepositoryNotFoundError):
    print("ACCESS_DENIED")
except Exception:
    print("ACCESS_CHECK_FAILED")
PYTHON
)
    case $status in
        ACCESS_GRANTED) return 0 ;;
        ACCESS_DENIED) return 1 ;;
        *) return 2 ;;
    esac
}

confirm_huggingface_model_access() {
    local name=$1 access_status response
    local repository="MuScriptor/muscriptor-$name"
    while true; do
        if check_huggingface_model_access "$repository"; then
            return
        fi
        access_status=$?
        if [[ $access_status -eq 2 ]]; then
            die 'The Hugging Face access check could not be completed. Check your internet connection and token.'
        fi

        warn "Your Hugging Face account does not have access to model '$name' yet."
        printf 'Open this page, accept the terms or request access: https://huggingface.co/%s\n' "$repository"
        [[ $NON_INTERACTIVE == false && -t 0 ]] || die "Model '$name' requires Hugging Face access. Grant access at https://huggingface.co/$repository, then run the command again."
        read -r -p 'After access is granted, press Enter to retry; type Q to cancel: ' response
        [[ $response =~ ^[Qq]$ ]] && die "Download cancelled. Grant access at https://huggingface.co/$repository, then run the command again."
    done
}

download_model() {
    local name=$1 force=$2 repository
    repository="MuScriptor/muscriptor-$name"
    step "Downloading model '$name'"
    printf 'License page: https://huggingface.co/%s\n' "$repository"
    if ! MUSCRIPTOR_DOWNLOAD_REPO=$repository MUSCRIPTOR_FORCE_DOWNLOAD=$force "$PYTHON_EXE" - <<'PYTHON'
import os
import sys
from huggingface_hub import hf_hub_download
from huggingface_hub.errors import GatedRepoError

repository = os.environ["MUSCRIPTOR_DOWNLOAD_REPO"]
force_download = os.environ["MUSCRIPTOR_FORCE_DOWNLOAD"] == "true"
try:
    print("Downloading config.json...", flush=True)
    for filename in ("config.json", "model.safetensors"):
        if filename == "model.safetensors":
            print("Downloading model weights. This can take several minutes...", flush=True)
        print(f"cached: {hf_hub_download(repo_id=repository, filename=filename, force_download=force_download)}")
except GatedRepoError:
    print("ACCESS_DENIED")
    sys.exit(3)
except Exception:
    print("DOWNLOAD_FAILED")
    sys.exit(1)
PYTHON
    then
        die "Unable to download '$name'. Check your internet connection and run the command again."
    fi
    get_model_state "$name"
    [[ -n $MODEL_WEIGHTS ]] || die "The download completed, but model '$name' was not found in the expected cache."
    info "Model '$name' is ready ($(awk "BEGIN {printf \"%.2f\", $MODEL_SIZE / 1073741824}") GB)."
}

ensure_models() {
    local force=$1
    shift
    local -a missing=() names=("$@")
    local name
    for name in "${names[@]}"; do
        get_model_state "$name"
        if [[ $force == true || -z $MODEL_WEIGHTS ]]; then
            missing+=("$name")
        else
            info "Model '$name' is already downloaded."
        fi
    done
    [[ ${#missing[@]} -gt 0 ]] || return
    resolve_huggingface_token
    for name in "${missing[@]}"; do
        confirm_huggingface_model_access "$name"
        download_model "$name" "$force"
    done
}

server_pid() {
    [[ -f $PID_FILE ]] || return 1
    local pid
    pid=$(<"$PID_FILE")
    [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
    printf '%s\n' "$pid"
}

stop_server() {
    local pid
    if ! pid=$(server_pid); then
        rm -f "$PID_FILE" "$STATE_FILE"
        return
    fi
    kill "$pid" 2>/dev/null || true
    for _ in {1..20}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
    done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
    rm -f "$PID_FILE" "$STATE_FILE"
}

port_is_open() {
    local connect_address=$BIND_ADDRESS
    [[ $connect_address == 0.0.0.0 || $connect_address == :: ]] && connect_address=127.0.0.1
    "$PYTHON_EXE" - "$connect_address" "$PORT" <<'PYTHON' >/dev/null 2>&1
import socket
import sys

with socket.socket() as sock:
    sock.settimeout(0.25)
    raise SystemExit(0 if sock.connect_ex((sys.argv[1], int(sys.argv[2]))) == 0 else 1)
PYTHON
}

assert_device_available() {
    local torch_info
    torch_info=$("$PYTHON_EXE" - <<'PYTHON'
import torch
print(f"PyTorch {torch.__version__}")
if torch.cuda.is_available():
    print(f"CUDA {torch.version.cuda}: {torch.cuda.get_device_name(0)}")
else:
    print("CUDA is not available; automatic mode will use CPU.")
PYTHON
)
    printf '%s\n' "$torch_info"
    if [[ $DEVICE == cuda && $torch_info == *'CUDA is not available'* ]]; then
        die '--device cuda was requested, but CUDA is unavailable. Use --device cpu or update the NVIDIA driver and run --update.'
    fi
}

start_background() {
    [[ -z $(server_pid || true) ]] || die "MuScriptor is already running (PID $(server_pid)). Use --restart or --stop."
    port_is_open && die "Port $PORT is already in use on $BIND_ADDRESS. Choose another value with --port."
    mkdir -p "$LOG_PATH"
    step 'Starting MuScriptor in the background'
    nohup "$PYTHON_EXE" -m muscriptor serve --model "$MODEL_WEIGHTS" --device "$DEVICE" --host "$BIND_ADDRESS" --port "$PORT" >"$STDOUT_LOG" 2>"$STDERR_LOG" < /dev/null &
    local pid=$!
    printf '%s\n' "$pid" > "$PID_FILE"
    printf 'pid=%s\nmodel=%s\ndevice=%s\nport=%s\n' "$pid" "$MODEL" "$DEVICE" "$PORT" > "$STATE_FILE"
    for _ in {1..120}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            tail -n 30 "$STDERR_LOG" >&2 || true
            rm -f "$PID_FILE" "$STATE_FILE"
            die 'MuScriptor exited during startup.'
        fi
        if port_is_open; then
            info "Server is ready (PID $pid)."
            local browser_address=$BIND_ADDRESS
            [[ $browser_address == 0.0.0.0 || $browser_address == :: ]] && browser_address=127.0.0.1
            printf 'Web UI: http://%s:%s/\nLogs: %s and %s\n' "$browser_address" "$PORT" "$STDOUT_LOG" "$STDERR_LOG"
            return
        fi
        sleep 0.5
    done
    warn "The process is still running, but port $PORT did not become ready. Check $STDERR_LOG."
}

start_console() {
    port_is_open && die "Port $PORT is already in use on $BIND_ADDRESS. Choose another value with --port."
    step 'Starting MuScriptor in the current console'
    local browser_address=$BIND_ADDRESS
    [[ $browser_address == 0.0.0.0 || $browser_address == :: ]] && browser_address=127.0.0.1
    printf 'Model: %s | Device: %s\nWeb UI: http://%s:%s/\nPress Ctrl+C to stop.\n' "$MODEL" "$DEVICE" "$browser_address" "$PORT"
    "$MUSCRIPTOR_EXE" serve --model "$MODEL_WEIGHTS" --device "$DEVICE" --host "$BIND_ADDRESS" --port "$PORT"
}

show_status() {
    local pid version
    if pid=$(server_pid); then info "Server: running (PID $pid)"; else printf 'Server: stopped\n'; fi
    if version=$(muscriptor_version 2>/dev/null); then info "Environment: installed (MuScriptor $version)"; else warn 'Environment: not installed'; fi
    show_model_status
    show_gpu_status
}

uninstall() {
    step 'Uninstalling MuScriptor'
    stop_server
    local remove_installation_root=false
    if can_remove_installation_root; then remove_installation_root=true; fi
    unregister_installation_directory
    remove_from_user_path
    rm -rf "$ENV_PATH" "$CACHE_PATH" "$LOG_PATH" "$PID_FILE" "$STATE_FILE"
    if [[ $remove_installation_root == true && -d $DIRECTORY ]]; then
        printf 'Removing installation directory: %s\n' "$DIRECTORY"
        rm -rf "$DIRECTORY"
    elif [[ -d $DIRECTORY ]]; then
        warn "Installation directory was retained because it contains files not managed by MuScriptor: $DIRECTORY"
    fi
    if [[ $CLEAR_SAVED_TOKEN == true ]]; then
        rm -f "$TOKEN_FILE"
        info 'Saved HF_TOKEN removed.'
    fi
    info 'Uninstall complete.'
}

main() {
    [[ $(uname -s) == Linux ]] || die 'This manager targets Linux. Use muscriptor_manager.ps1 on Windows.'
    parse_arguments "$@"
    resolve_installation_directory
    if [[ $ACTION != uninstall ]]; then
        initialize_manager_directory
    fi

    case $ACTION in
        uninstall) uninstall; return ;;
        stop) step 'Stopping MuScriptor'; stop_server; info 'Server stopped.'; return ;;
        status) show_status; return ;;
        list-models) step 'Downloaded models'; show_model_status; return ;;
        gpu-info) step 'GPU and CUDA compatibility'; show_gpu_status; return ;;
        install) ensure_environment false; return ;;
        update) ensure_environment true; return ;;
        download) ensure_environment false; ensure_models "$FORCE_DOWNLOAD" "$MODEL"; show_model_status; return ;;
        download-all) ensure_environment false; ensure_models "$FORCE_DOWNLOAD" "${MODEL_NAMES[@]}"; show_model_status; return ;;
    esac

    ensure_environment false
    if [[ $RESTART == true ]]; then stop_server; fi
    ensure_models false "$MODEL"
    get_model_state "$MODEL"
    [[ -n $MODEL_WEIGHTS ]] || die "Model '$MODEL' is not available after download."
    assert_device_available
    if [[ $START_BACKGROUND == true || $RESTART == true ]]; then start_background; else start_console; fi
}

main "$@"
