# Runs MS's WSUS Server Cleanup via the UpdateServices Invoke-WsusServerCleanup cmdlet.
# -Operations is a comma-scalar split inside because powershell -File cannot pass arrays. Each
# operation is allowlist-validated before splatting so a bad override cannot inject -WhatIf or
# -Confirm. Logs each result line.
param([Parameter(Mandatory)][string]$LogDir, [Parameter(Mandatory)][string]$Operations)
$ErrorActionPreference = 'Stop'
$allowed = @('DeclineSupersededUpdates', 'DeclineExpiredUpdates', 'CleanupObsoleteComputers', 'CleanupObsoleteUpdates', 'CleanupUnneededContentFiles', 'CompressUpdates')
$log = Join-Path $LogDir ('WsusCleanup_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
function Write-Log([string]$Message) {
    Add-Content -LiteralPath $log -Value ((Get-Date -Format s) + '  ' + $Message)
}
try {
    $ops = $Operations.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $bad = @($ops | Where-Object { $allowed -notcontains $_ })
    if ($bad.Count -gt 0) {
        throw ('unknown/disallowed cleanup operation(s): ' + ($bad -join ', '))
    }
    if ($ops.Count -eq 0) {
        throw 'no cleanup operations specified'
    }
    Write-Log ('WSUS cleanup starting (operations: ' + ($ops -join ', ') + ')')
    $params = @{}
    foreach ($op in $ops) { $params[$op] = $true }
    $results = Get-WsusServer | Invoke-WsusServerCleanup @params
    foreach ($line in $results) { Write-Log ('  ' + [string]$line) }
    Write-Log 'WSUS cleanup completed'
    exit 0
} catch {
    try { Write-Log ('WSUS cleanup FAILED: ' + $_.Exception.Message) } catch { }
    exit 1
}
