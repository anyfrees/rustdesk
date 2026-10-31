param(
    [string]$ToolRoot = "$env:USERPROFILE\.codex\tools\nnu-build",
    [string]$OutputDirectory = "$PSScriptRoot\..\..\NNU-Output",
    [switch]$SkipPrepare,
    [switch]$UiOnly
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
Set-Location -LiteralPath $repo
if ([string]::IsNullOrEmpty($env:NNU_PORTABLE_PASSWORD)) {
    throw 'Set NNU_PORTABLE_PASSWORD in this process before building.'
}
$env:RUSTUP_TOOLCHAIN = '1.75.0'
$env:VCPKG_ROOT = "$ToolRoot\vcpkg"
$env:VCPKG_VISUAL_STUDIO_PATH = 'C:\BuildTools'
$env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
$env:LIBCLANG_PATH = "$ToolRoot\llvm\bin"
$env:CARGO_BUILD_JOBS = '8'
$pythonDirectory = Split-Path (py -c 'import sys; print(sys.executable)')
$env:Path = "$ToolRoot\flutter\bin;$ToolRoot\llvm\bin;$pythonDirectory;$pythonDirectory\Scripts;$env:Path"

function Run-Step([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE" }
}

if (-not $SkipPrepare) {
Expand-Archive -LiteralPath res\nnu\bridge-1.5.0.zip -DestinationPath $repo -Force
Push-Location flutter
try {
    $pubOutput = & flutter pub get 2>&1
    $pubResult = $LASTEXITCODE
    $pubOutput | Write-Host
    if ($pubResult -ne 0 -and ($pubOutput -join "`n") -notmatch 'symlink support') {
        throw 'Flutter dependency resolution failed.'
    }
    $plugins = Get-Content .flutter-plugins-dependencies -Raw | ConvertFrom-Json
    foreach ($platform in @('windows', 'linux')) {
        $linkRoot = Join-Path (Get-Location) "$platform\flutter\ephemeral\.plugin_symlinks"
        New-Item -ItemType Directory -Force -Path $linkRoot | Out-Null
        foreach ($plugin in $plugins.plugins.$platform) {
            $linkPath = Join-Path $linkRoot $plugin.name
            if (-not (Test-Path -LiteralPath $linkPath)) {
                New-Item -ItemType Junction -Path $linkPath -Target $plugin.path | Out-Null
            }
        }
    }
    Run-Step 'flutter' @('pub', 'get', '--offline')
} finally { Pop-Location }

Run-Step "$ToolRoot\vcpkg\vcpkg.exe" @('install', '--triplet', 'x64-windows-static', '--host-triplet', 'x64-windows-static', "--x-install-root=$ToolRoot\vcpkg\installed")
}
Run-Step 'rustc' @('--edition=2021', '--test', 'res/nnu/test_bootstrap.rs', '-o', "$ToolRoot\nnu-bootstrap-tests.exe")
Run-Step "$ToolRoot\nnu-bootstrap-tests.exe" @()
$buildArguments = @('build.py', '--portable', '--flutter', '--skip-portable-pack', '--hwcodec', '--vram')
if ($UiOnly) { $buildArguments += '--skip-cargo' }
Run-Step 'py' $buildArguments

$distribution = Join-Path $repo 'flutter\build\windows\x64\runner\Release'
Copy-Item "$ToolRoot\RustDeskTempTopMostWindow\WindowInjection\x64\Release\WindowInjection.dll" $distribution -Force
Run-Step 'py' @('res/nnu/package-drivers.py', '--tools', $ToolRoot, '--dist', $distribution)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

Push-Location libs\portable
try {
    Run-Step 'py' @('generate.py', '-f', $distribution, '-o', '.', '-e', "$distribution\rustdesk.exe")
} finally { Pop-Location }
Copy-Item target\release\rustdesk-portable-packer.exe "$OutputDirectory\RustDesk-NNU-1.5.0-x64-Portable.exe" -Force
Copy-Item target\release\rustdesk-portable-packer.exe "$OutputDirectory\RustDesk-NNU-1.5.0-x64-Install.exe" -Force

Push-Location res\msi
try {
    Run-Step 'py' @('preprocess.py', '--arp', '-d', $distribution)
    Run-Step "$ToolRoot\nuget.exe" @('restore', 'msi.sln', '-NonInteractive')
    Run-Step 'C:\BuildTools\MSBuild\Current\Bin\MSBuild.exe' @('msi.sln', '-p:Configuration=Release', '-p:Platform=x64', '/p:TargetVersion=Windows10')
    $msi = Get-ChildItem Package\bin\*\Release\en-us\Package.msi | Select-Object -First 1
    if (-not $msi) { throw 'MSI output is missing.' }
    Copy-Item -LiteralPath $msi.FullName -Destination "$OutputDirectory\RustDesk-NNU-1.5.0-x64.msi" -Force
} finally { Pop-Location }

Copy-Item docs\NNU-Windows.md "$OutputDirectory\README.md" -Force
Copy-Item LICENCE "$OutputDirectory\LICENCE" -Force
Compress-Archive -Path "$distribution\*" -DestinationPath "$OutputDirectory\RustDesk-NNU-1.5.0-x64.zip" -Force
Get-ChildItem -LiteralPath $OutputDirectory -File | Where-Object Name -ne 'SHA256SUMS.txt' | Sort-Object Name | ForEach-Object {
    $digest = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$digest  $($_.Name)"
} | Set-Content "$OutputDirectory\SHA256SUMS.txt" -Encoding ascii
Write-Host "Packages: $OutputDirectory"
