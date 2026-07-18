# Deletes IIS W3C log files older than -MaxAgeDays under -LogPath (recursively, incl. the W3SVC<id>
# subfolders). IIS has no built-in log retention; the C13g scheduled task runs this weekly off-hours as
# SYSTEM. Bounded delete: *.log FILES only, under -LogPath only. Logs start/count/end to a timestamped file.
# Mirrors files/Invoke-SusdbReindex.ps1 (structure, error handling, exit codes). wsus role C13f.
param([Parameter(Mandatory)][string]$LogPath, [Parameter(Mandatory)][int]$MaxAgeDays, [Parameter(Mandatory)][string]$LogDir)
$ErrorActionPreference = 'Stop'
$log = Join-Path $LogDir ('IisLogCleanup_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
function Write-Log([string]$Message) {
    Add-Content -LiteralPath $log -Value ((Get-Date -Format s) + '  ' + $Message)
}
try {
    if (-not (Test-Path -LiteralPath $LogPath)) {
        Write-Log ('IIS log path not found, nothing to clean: ' + $LogPath)
        exit 0
    }
    $cutoff = (Get-Date).AddDays(-[math]::Abs($MaxAgeDays))
    Write-Log ('IIS log cleanup starting (path: ' + $LogPath + ', deleting *.log older than ' + $cutoff + ')')
    $old = @(Get-ChildItem -LiteralPath $LogPath -Recurse -File -Filter '*.log' | Where-Object { $_.LastWriteTime -lt $cutoff })
    $n = 0
    foreach ($f in $old) {
        Remove-Item -LiteralPath $f.FullName -Force
        $n++
    }
    Write-Log ('IIS log cleanup completed (' + $n + ' file(s) deleted)')
    exit 0
} catch {
    try { Write-Log ('IIS log cleanup FAILED: ' + $_.Exception.Message) } catch { }
    exit 1
}
