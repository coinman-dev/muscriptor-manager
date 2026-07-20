# MuScriptor Manager

PowerShell and Bash managers for installing, updating, and running [MuScriptor](https://github.com/MuScriptor/muscriptor) on Windows and Linux with NVIDIA GPU detection and Hugging Face model downloads.

The manager is not affiliated with MuScriptor, Hugging Face, NVIDIA, or PyTorch.

## Features

- Installs `uv`, Python 3.12, MuScriptor, and an appropriate PyTorch build.
- Includes `muscriptor_manager.ps1` for Windows and `muscriptor_manager.sh` for Linux.
- Detects NVIDIA GPU generation, driver version, and CUDA compatibility.
- Supports `small`, `medium`, and `large` MuScriptor models.
- Downloads models only when they are missing and checks their cache state.
- Requests a Hugging Face token when it is required; tokens are not saved unless `-SaveToken` is supplied.
- Starts the web UI in the current console or in the background.
- Uses UTF-8 for Python output on Windows consoles configured with legacy code pages.
- Registers the installation root as `Muscriptor`, validates the environment beneath it before reuse, and removes the registration on uninstall.
- Adds the selected installation directory to the current user's `PATH` after a successful installation and removes it on uninstall.

## Requirements

- Windows 10 or Windows 11 with Windows PowerShell 5.1 or PowerShell 7+, or a Linux distribution with Bash 4+.
- Internet access for the first installation and model download.
- An NVIDIA GPU and current driver for CUDA acceleration. CPU mode is supported but is considerably slower.

## Windows Quick Start

Open PowerShell in the directory containing the script and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\muscriptor_manager.ps1
```

On the first installation, the script proposes `D:\Muscriptor` when drive `D:` exists; otherwise it proposes `C:\Muscriptor`. Enter another directory if needed. After a successful installation, the manager records that root in the `Muscriptor` environment variable and verifies its Python and MuScriptor executables before reusing it. Run PowerShell as Administrator to save `Muscriptor` as a system variable; otherwise it is saved for the current user.

The Web UI is available at `http://127.0.0.1:8222/`. Press `Ctrl+C` to stop a foreground server.

## Linux Quick Start

Make the Bash manager executable and run it:

```bash
chmod +x muscriptor_manager.sh
./muscriptor_manager.sh
```

On the first installation, the script proposes `~/.local/share/muscriptor`. Enter another directory if needed. After a successful installation, the manager stores `Muscriptor` in `~/.config/muscriptor-manager/installation.sh`, loads it itself, and exposes it through `.bashrc`. The server is available at `http://127.0.0.1:8222/`; press `Ctrl+C` to stop a foreground server.

## Windows Commands

```powershell
# Show detected GPU, driver, and recommended PyTorch CUDA build
.\muscriptor_manager.ps1 -GpuInfo

# Install or repair only the environment
.\muscriptor_manager.ps1 -Install

# Update MuScriptor and the selected PyTorch CUDA build
.\muscriptor_manager.ps1 -Update

# Run a specific model
.\muscriptor_manager.ps1 -Model small
.\muscriptor_manager.ps1 -Model medium
.\muscriptor_manager.ps1 -Model large

# Download models without starting the server
.\muscriptor_manager.ps1 -Download -Model medium
.\muscriptor_manager.ps1 -DownloadAll

# Run in the background, inspect status, then stop it
.\muscriptor_manager.ps1 -Start
.\muscriptor_manager.ps1 -Status
.\muscriptor_manager.ps1 -Stop

# Use a specific installation directory
.\muscriptor_manager.ps1 -Directory 'D:\Muscriptor' -Model large

# Remove the managed environment, cache, logs, and PATH entry
.\muscriptor_manager.ps1 -Uninstall
```

Run `.\muscriptor_manager.ps1 -Help` for every available option.

## Linux Commands

```bash
# Show detected GPU, driver, and recommended PyTorch CUDA build
./muscriptor_manager.sh --gpu-info

# Install or repair only the environment
./muscriptor_manager.sh --install

# Update MuScriptor and the selected PyTorch CUDA build
./muscriptor_manager.sh --update

# Run a specific model or start in the background
./muscriptor_manager.sh --model medium
./muscriptor_manager.sh --model small --start

# Download models without starting the server
./muscriptor_manager.sh --download --model medium
./muscriptor_manager.sh --download-all

# Inspect and stop the background server
./muscriptor_manager.sh --status
./muscriptor_manager.sh --stop

# Use a specific installation directory
./muscriptor_manager.sh --directory /mnt/models/muscriptor --model large

# Remove the managed environment, cache, logs, and Bash PATH entry
./muscriptor_manager.sh --uninstall
```

Run `./muscriptor_manager.sh --help` for every available option.

## Hugging Face Token

Some model downloads require a Hugging Face read token. The script requests one interactively when necessary:

```powershell
.\muscriptor_manager.ps1 -Token hf_your_token_here -Download -Model large
```

On Windows, use `-SaveToken` only if you explicitly want the token stored in the user-level `HF_TOKEN` environment variable. On Linux, use `--save-token` only if you explicitly want the token stored in a mode-600 user config file. Do not commit tokens, caches, logs, or local installation directories to Git.

## CUDA Notes

The manager selects a PyTorch build based on GPU compute capability and the installed NVIDIA driver.

- RTX 20xx, 30xx, and 40xx use the newest compatible CUDA build supported by their driver.
- RTX 50xx requires the `cu130` build and an NVIDIA driver version `580.65` or newer.
- Pascal GPUs, such as GTX 1070 Ti, use `cu126` when supported by the driver.

The scripts install the PyTorch CUDA runtime, not the NVIDIA driver. Update the driver from [NVIDIA's driver download page](https://www.nvidia.com/Download/index.aspx) or your Linux distribution's NVIDIA driver package when the manager requests it.

## Development

Run the following before submitting a change:

```powershell
Invoke-ScriptAnalyzer -Path .\muscriptor_manager.ps1
```

```bash
shellcheck muscriptor_manager.sh
bash -n muscriptor_manager.sh
```

GitHub Actions runs PowerShell parsing, PSScriptAnalyzer, Bash syntax, and ShellCheck for every push and pull request.

## License

This project is distributed under the [MIT License](LICENSE).
