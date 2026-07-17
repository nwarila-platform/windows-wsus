# Runs the MS SUSDBMaint.sql reindex against WID-hosted SUSDB via System.Data.SqlClient over
# the WID named pipe because Server 2025 ships no sqlcmd (mirrors the C06 idiom). Splits on GO
# because SqlClient cannot process GO. CommandTimeout=0 runs to completion; the C09b scheduled
# task bounds runtime and prevents overlap. SQL PRINT output is captured via InfoMessage.
param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$LogDir)
$ErrorActionPreference = 'Stop'
$log = Join-Path $LogDir ('SUSDBReindex_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
function Write-Log([string]$Message) {
    Add-Content -LiteralPath $log -Value ((Get-Date -Format s) + '  ' + $Message)
}
$conn = $null
try {
    Write-Log ('SUSDB reindex starting (script: ' + $ScriptPath + ')')
    $sql = Get-Content -Raw -LiteralPath $ScriptPath
    $batches = [regex]::Split($sql, '(?im)^\s*GO\s*$')
    $conn = New-Object System.Data.SqlClient.SqlConnection('server=\\.\pipe\MICROSOFT##WID\tsql\query;database=SUSDB;trusted_connection=true;')
    $conn.add_InfoMessage({ param($s, $e) Write-Log ('  [SQL] ' + $e.Message) })
    $conn.Open()
    $n = 0
    foreach ($batch in $batches) {
        if ([string]::IsNullOrWhiteSpace($batch)) { continue }
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $batch
        $cmd.CommandTimeout = 0
        [void]$cmd.ExecuteNonQuery()
        $n++
    }
    Write-Log ('SUSDB reindex completed (' + $n + ' batches)')
    exit 0
} catch {
    try { Write-Log ('SUSDB reindex FAILED: ' + $_.Exception.Message) } catch { }
    exit 1
} finally {
    if ($conn -and $conn.State -eq 'Open') { $conn.Close() }
}
