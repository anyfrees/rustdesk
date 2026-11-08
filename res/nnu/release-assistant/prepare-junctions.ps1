param([Parameter(Mandatory=$true)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
$pluginFile = Join-Path $BuildRoot 'flutter\.flutter-plugins-dependencies'
$plugins = Get-Content -LiteralPath $pluginFile -Raw | ConvertFrom-Json
foreach ($platform in @('windows', 'linux')) {
    $linkRoot = Join-Path $BuildRoot "flutter\$platform\flutter\ephemeral\.plugin_symlinks"
    New-Item -ItemType Directory -Force -Path $linkRoot | Out-Null
    foreach ($plugin in $plugins.plugins.$platform) {
        $linkPath = Join-Path $linkRoot $plugin.name
        if (-not (Test-Path -LiteralPath $linkPath)) {
            New-Item -ItemType Junction -Path $linkPath -Target $plugin.path | Out-Null
        }
    }
}
