param([string]$OutputDirectory = "$PSScriptRoot\..\..\..\..\dist\RUSTDESK版本发布助手")
$ErrorActionPreference = 'Stop'
$taskOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
$taskWork = Join-Path $env:LOCALAPPDATA 'NNU\ReleaseAssistant\pyinstaller'
New-Item -ItemType Directory -Force -Path $taskOutput, $taskWork | Out-Null
$assetOutput = py "$PSScriptRoot\prepare_resources.py"
if ($LASTEXITCODE -ne 0) { throw '助手组件准备失败' }
$taskAssets = $assetOutput | Select-Object -Last 1
py -m PyInstaller --noconfirm --onefile --windowed --name 'RUSTDESK版本发布助手' --icon "$PSScriptRoot\assets\assistant.ico" --collect-all customtkinter --paths $taskAssets --hidden-import embedded_signing_key --add-data "$PSScriptRoot\assets\assistant.ico;assets" --add-data "$PSScriptRoot\assets\licenses;licenses" --add-data "$taskAssets\resources;resources" --add-data "$taskAssets\signing-key.dpapi;." --distpath $taskOutput --workpath "$taskWork\build" --specpath $taskWork "$PSScriptRoot\app.py"
if ($LASTEXITCODE -ne 0) { throw '助手打包失败' }
Write-Host "单文件程序：$taskOutput\RUSTDESK版本发布助手.exe"
