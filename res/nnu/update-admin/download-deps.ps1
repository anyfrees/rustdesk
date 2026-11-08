$ErrorActionPreference = 'Stop'
py -m pip download --only-binary=:all: --platform manylinux_2_34_x86_64 --platform manylinux_2_28_x86_64 --platform manylinux_2_26_x86_64 --platform manylinux2014_x86_64 --python-version 312 --dest "$PSScriptRoot\wheels" -r "$PSScriptRoot\requirements.txt"
if ($LASTEXITCODE -ne 0) { throw 'Dependency download failed' }
