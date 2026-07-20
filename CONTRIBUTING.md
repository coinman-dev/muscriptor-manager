# Contributing

1. Create a branch from `main`.
2. Keep changes focused and avoid committing local MuScriptor environments, model caches, logs, or tokens.
3. Run the checks below on Windows PowerShell or PowerShell 7:

```powershell
Invoke-ScriptAnalyzer -Path .\muscriptor_manager.ps1
.\muscriptor_manager.ps1 -Help
```

```bash
shellcheck muscriptor_manager.sh
bash -n muscriptor_manager.sh
./muscriptor_manager.sh --help
```

4. Open a pull request describing the user-visible behavior and the validation performed.

Bug reports should include the PowerShell version, Windows version, GPU model, NVIDIA driver version, selected model, and the relevant error output with secrets removed.
