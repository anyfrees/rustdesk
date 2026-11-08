param([Parameter(Mandatory=$true)][string]$PlanPath)
$ErrorActionPreference = 'Stop'
$taskPlan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
$taskRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PlanPath))
$taskTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $taskRoot.StartsWith($taskTemp,[StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($taskRoot) -notmatch '^nnu-client-update-[0-9a-f-]{36}$') { throw 'Invalid update staging directory' }
$taskPackage = [IO.Path]::GetFullPath($taskPlan.PackagePath)
$taskTarget = [IO.Path]::GetFullPath($taskPlan.TargetPath)
$taskRunning = [IO.Path]::GetFullPath($taskPlan.RunningExe)
if (-not $taskPackage.StartsWith($taskRoot + '\',[StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetExtension($taskTarget) -ine '.exe' -or
    $taskPlan.Kind -notin @('portable','zip') -or
    ($taskPlan.Kind -eq 'zip' -and $taskTarget -ine $taskRunning)) { throw 'Invalid portable update plan' }
$taskLogDir = Join-Path $env:LOCALAPPDATA 'NNU\ClientUpdates'
New-Item -ItemType Directory -Path $taskLogDir -Force | Out-Null
$taskLog = Join-Path $taskLogDir 'update.log'
$taskJournal = [System.Collections.Generic.List[object]]::new()
$taskStopped = $false
$taskWindowState = if ($taskPlan.WindowState -in @('hidden','minimized','maximized','normal')) { $taskPlan.WindowState } else { 'hidden' }
$taskRestoreArgs = @("--nnu-update-window=$taskWindowState")
$taskRestoreStyle = switch ($taskWindowState) { 'hidden' { 'Hidden' } 'minimized' { 'Minimized' } 'maximized' { 'Maximized' } default { 'Normal' } }
$taskPackageStream = $null
try {
    $taskPackageStream = [IO.File]::Open($taskPackage,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $taskHasher = [Security.Cryptography.SHA256]::Create()
    $taskDigest = [BitConverter]::ToString($taskHasher.ComputeHash($taskPackageStream)).Replace('-','').ToLowerInvariant()
    $taskHasher.Dispose()
    if ($taskDigest -cne $taskPlan.Digest) { throw 'Package changed after verification' }
    $taskPackageStream.Position = 0
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class NnuUpdateIdle { [StructLayout(LayoutKind.Sequential)] public struct Info { public uint Size; public uint Tick; } [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref Info value); [DllImport("kernel32.dll")] public static extern uint GetTickCount(); }'
    $taskInput = [NnuUpdateIdle+Info]::new()
    $taskInput.Size = [Runtime.InteropServices.Marshal]::SizeOf($taskInput)
    if (-not [NnuUpdateIdle]::GetLastInputInfo([ref]$taskInput) -or
        (([uint64][NnuUpdateIdle]::GetTickCount() + 4294967296 - $taskInput.Tick) % 4294967296) -lt 300000) { throw 'User became active; update postponed' }
    $taskFiles = [System.Collections.Generic.List[object]]::new()
    if ($taskPlan.Kind -eq 'zip') {
        Add-Type -AssemblyName System.IO.Compression
        $taskExpanded = Join-Path $taskRoot 'expanded'
        New-Item -ItemType Directory -Path $taskExpanded | Out-Null
        $taskArchive = [IO.Compression.ZipArchive]::new($taskPackageStream,[IO.Compression.ZipArchiveMode]::Read,$true)
        try {
            $taskSize = 0L
            foreach ($taskEntry in $taskArchive.Entries) {
                $taskSize += $taskEntry.Length
                $taskOut = [IO.Path]::GetFullPath((Join-Path $taskExpanded $taskEntry.FullName))
                if ($taskSize -gt 1073741824 -or $taskArchive.Entries.Count -gt 4096 -or
                    -not $taskOut.StartsWith($taskExpanded + '\',[StringComparison]::OrdinalIgnoreCase) -or
                    (($taskEntry.ExternalAttributes -shr 16) -band 61440) -eq 40960) { throw 'Unsafe ZIP update path or size' }
                if ($taskEntry.FullName.EndsWith('/')) { continue }
                New-Item -ItemType Directory -Path (Split-Path -Parent $taskOut) -Force | Out-Null
                $taskInputFile = $taskEntry.Open()
                $taskOutputFile = [IO.File]::Create($taskOut)
                try { $taskInputFile.CopyTo($taskOutputFile) } finally { $taskInputFile.Dispose(); $taskOutputFile.Dispose() }
                $taskFiles.Add([pscustomobject]@{Source=$taskOut; Relative=$taskEntry.FullName})
            }
        } finally { $taskArchive.Dispose() }
        if (-not (Test-Path -LiteralPath (Join-Path $taskExpanded ([IO.Path]::GetFileName($taskRunning))))) { throw 'ZIP package lacks client executable' }
    } else { $taskFiles.Add([pscustomobject]@{Source=$taskPackage; Relative=[IO.Path]::GetFileName($taskTarget)}) }
    $taskProgramDir = [IO.Path]::GetFullPath((Split-Path -Parent $taskTarget))
    if ($taskProgramDir -eq [IO.Path]::GetPathRoot($taskProgramDir)) { throw 'Refusing update in a drive root' }
    foreach ($taskFile in $taskFiles) {
        $taskDest = [IO.Path]::GetFullPath((Join-Path $taskProgramDir $taskFile.Relative))
        if (-not $taskDest.StartsWith($taskProgramDir + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Target escapes client directory' }
        $taskAncestor = $taskDest
        while ($taskAncestor.StartsWith($taskProgramDir,[StringComparison]::OrdinalIgnoreCase)) {
            if ((Test-Path -LiteralPath $taskAncestor) -and ((Get-Item -LiteralPath $taskAncestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Update target contains a junction or symbolic link' }
            if ($taskAncestor -eq $taskProgramDir) { break }
            $taskAncestor = Split-Path -Parent $taskAncestor
        }
    }
    $taskProcesses = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -ieq $taskRunning -and $_.SessionId -eq $taskPlan.SessionId })
    if ($taskProcesses.Count -eq 0) { throw 'Cannot identify the running portable client' }
    foreach ($taskProcess in $taskProcesses) { Stop-Process -Id $taskProcess.ProcessId -ErrorAction Stop }
    foreach ($taskProcess in $taskProcesses) { Wait-Process -Id $taskProcess.ProcessId -Timeout 30 -ErrorAction SilentlyContinue }
    $taskStopped = $true
    foreach ($taskFile in $taskFiles) {
        $taskDest = [IO.Path]::GetFullPath((Join-Path $taskProgramDir $taskFile.Relative))
        $taskOld = $taskDest + '.nnu-old-' + [guid]::NewGuid().ToString()
        $taskNew = $taskDest + '.nnu-new-' + [guid]::NewGuid().ToString()
        if (-not $taskNew.StartsWith($taskProgramDir + '\',[StringComparison]::OrdinalIgnoreCase) -or
            -not $taskOld.StartsWith($taskProgramDir + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Replacement path escapes client directory' }
        $taskExisted = Test-Path -LiteralPath $taskDest
        New-Item -ItemType Directory -Path (Split-Path -Parent $taskDest) -Force | Out-Null
        try {
            Copy-Item -LiteralPath $taskFile.Source -Destination $taskNew
            if ($taskExisted) { [IO.File]::Replace($taskNew,$taskDest,$taskOld) }
            else { [IO.File]::Move($taskNew,$taskDest) }
            $taskJournal.Add([pscustomobject]@{Target=$taskDest; Backup=$taskOld; Existed=$taskExisted})
        } finally { if (Test-Path -LiteralPath $taskNew) { Remove-Item -LiteralPath $taskNew -Force } }
    }
    Start-Process -FilePath $taskTarget -ArgumentList $taskRestoreArgs -WorkingDirectory $taskProgramDir -WindowStyle $taskRestoreStyle
    Add-Content -LiteralPath $taskLog -Value "$(Get-Date -Format o) Updated to build $($taskPlan.Build)" -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach ($taskChange in $taskJournal) {
        if ($taskChange.Existed) { Remove-Item -LiteralPath $taskChange.Backup -Force -ErrorAction SilentlyContinue }
    }
    $taskPackageStream.Dispose(); $taskPackageStream = $null
    if ($taskRoot.StartsWith($taskTemp,[StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($taskRoot) -match '^nnu-client-update-[0-9a-f-]{36}$' -and
        -not ((Get-Item -LiteralPath $taskRoot).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $taskRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    for ($taskIndex = $taskJournal.Count-1; $taskIndex -ge 0; $taskIndex--) {
        $taskChange = $taskJournal[$taskIndex]
        try {
            if ($taskChange.Existed) { [IO.File]::Replace($taskChange.Backup,$taskChange.Target,$null) }
            elseif (Test-Path -LiteralPath $taskChange.Target) { Remove-Item -LiteralPath $taskChange.Target -Force }
        } catch { Add-Content -LiteralPath $taskLog -Value "Rollback needs attention: $($taskChange.Target)" -ErrorAction SilentlyContinue }
    }
    Add-Content -LiteralPath $taskLog -Value "$(Get-Date -Format o) Update failed: $($_.Exception.Message)" -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($taskStopped) { Start-Process -FilePath $taskTarget -ArgumentList $taskRestoreArgs -WorkingDirectory (Split-Path -Parent $taskTarget) -WindowStyle $taskRestoreStyle }
    exit 1
} finally { if ($null -ne $taskPackageStream) { $taskPackageStream.Dispose() } }
