#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Reads where a SQL Server instance would create a database, who may write there, and
        which files it currently has SUSDB attached from.

    .DESCRIPTION
        The effective directories are asked of the ENGINE rather than composed from the registry,
        because the two disagree until the service restarts. Measured on a live instance,
        2026-08-25: with the engine serving 'E:\MSSQL\Data', writing 'F:\DecoyProbe' into the
        registry left SERVERPROPERTY still reporting 'E:\MSSQL\Data'; it followed only after a
        restart. SERVERPROPERTY returns the value read AT STARTUP, so a host whose registry was
        pinned by a run that died before its restart reads as INVALID here and is repaired, where
        a registry comparison would have called it converged. Microsoft documents the restart
        requirement but not the pre-restart return value, which is why it was measured.

        A stopped instance is reported, not raised. The caller starts it; failing here would deny
        the very repair the caller exists to perform.

        The access check is by per-service SID, never by account name: that SID is derived from
        the service NAME rather than from the machine, so it is the identity a REPLACEMENT
        operating system reading the same volume would present -- which is what lets the data
        volume outlive the host. A grant is only counted when it is inheritable, since the engine
        creates files and subdirectories beneath these paths.

        Deny is reported separately and over a WIDER set of identities than the grant, because
        Deny wins over Allow and Windows evaluates every SID in the access token, not just the
        one the service runs as. The listed identities were READ FROM THE ENGINE'S OWN TOKEN on
        this image, 2026-08-25, rather than assumed: Everyone, LOCAL, CONSOLE LOGON, SERVICE,
        Authenticated Users, This Organization, BUILTIN\Users, BUILTIN\Performance Monitor Users
        and ALL SERVICES. A deny naming any of them blocks the engine as surely as one naming the
        service account.

        Read what this is and is not. The same measurement found a DYNAMIC logon SID in the token
        -- 'S-1-5-5-0-9735504', minted per logon -- which no fixed list can ever contain. So this
        reports the denies an operator or a hardening baseline actually writes, and it is NOT an
        effective-access computation: a deny naming that logon SID, or a local group the account
        was added to, is not seen here. Only the engine could settle those, by being asked to
        write. Treat a clean result as 'nothing this script can see denies the engine', never as
        'the engine can write'.

        This one script serves both the caller's read and its proof, exactly as the reference role
        re-runs its own read at END: the two cannot disagree about what counts as placed.

        Org scripts are a single straightforward process stage in the org script template's
        architecture: one [ Script ] region carrying [ Initialization ] (strict mode, transport
        detection, input normalization), [ Main ] (read -> build ONE result object), and
        [ Output ] (the same object to $Ansible or as JSON).

    .PARAMETER DebugLevel
        Three-digit control string configuring independent debugging functions, one digit each.
        First digit: ErrorActionPreference (0 SilentlyContinue, 1 Stop, 2 Continue, 3 Inquire,
        4 Ignore, 5 Suspend). Second digit: Set-PSDebug (0 off, 1 trace 1, 2 trace 2,
        3 trace 1 + step, 4 trace 2 + step). Third digit: Set-StrictMode (0 off, 1-3 that
        version). Default '103': stop on error, no tracing, strict mode 3.

    .PARAMETER LogLevel
        Six-digit control string setting the preference for each stream, in the order Verbose,
        Debug, Information, Warning, Error, Fatal. Each digit is an ActionPreference
        (0 SilentlyContinue, 1 Stop, 2 Continue, 3 Inquire, 4 Ignore, 5 Suspend).

    .PARAMETER ServiceName
        The Windows service the instance runs as. Its per-service SID is the identity whose access
        to the two directories is reported.

    .PARAMETER InstanceName
        The SQL Server instance to read, as it is registered under InstanceNamesKey.

    .PARAMETER InstanceNamesKey
        The registry key mapping instance names to their own directory names.

    .PARAMETER InstanceRoot
        The registry key the instance directories live under.

    .PARAMETER DesiredData
        The directory the caller intends the instance to create data files in.

    .PARAMETER DesiredLog
        The directory the caller intends the instance to create log files in.

    .EXAMPLE
        .\Get-SqlDatabasePlacement.ps1 -ServiceName 'MSSQLSERVER' -InstanceName 'MSSQLSERVER' `
            -InstanceNamesKey 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' `
            -InstanceRoot 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' `
            -DesiredData 'E:\MSSQL\Data' -DesiredLog 'E:\MSSQL\Log'

    .OUTPUTS
        One object carrying changed, check_mode, data_acl_denied, data_acl_granted,
        effective_data, effective_log, log_acl_denied, log_acl_granted, msg, placement_read,
        placement_valid, service_sid, service_start_mode, service_state, settings_key,
        susdb_data_path, susdb_file_count, susdb_log_path, susdb_read_only and susdb_state.

        The susdb_* fields answer two different questions. Attachment and location come from
        sys.master_files; serviceability -- susdb_state and susdb_read_only -- comes from
        sys.databases, because the catalog lists files for an OFFLINE database too and cannot
        speak for whether the database can be used. They are empty and zero on a host with no
        such database, which is what a first converge looks like before post-installation runs.

        placement_read says whether the engine could be ASKED. It separates "the instance was
        down, so its placement is unknown" from "the instance answered and named the wrong
        directory" -- two states that placement_valid alone reports identically, and that a
        caller deciding whether to restart the service must tell apart.
#>

[CmdletBinding(SupportsShouldProcess)]
[OutputType([System.Void])]
Param (
  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[0-5][0-4][0-3]$')]
  [System.String]
  $DebugLevel = '103',

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String]
  $LogLevel = '002223',

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $ServiceName,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $InstanceName,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $InstanceNamesKey,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $InstanceRoot,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[A-Za-z]:\\')]
  [System.String]
  $DesiredData,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[A-Za-z]:\\')]
  [System.String]
  $DesiredLog
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

# The module runs this script in check mode because it declares SupportsShouldProcess, and injects
# -WhatIf when it does. A read has nothing to suppress, and -WhatIf left on would suppress the
# New-Variable setup below, so it is neutralised here exactly as in the sibling scripts.
$WhatIfPreference = $false

# Initialize STATIC log level names, indexed by LogLevel digit position.
New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)

# Initialize the custom stream preferences; the built-in ones already exist.
New-Variable -Verbose:$False -Force -Name:'ErrorPreference' -Value:(
  [System.Management.Automation.ActionPreference]::Stop
)
New-Variable -Verbose:$False -Force -Name:'FatalPreference' -Value:(
  [System.Management.Automation.ActionPreference]::Stop
)

# Configure log levels based on the LogLevel parameter.
For ($L = 0; $L -lt 6; $L++) {
  Set-Variable -Verbose:$False -Force -Name:('{0}Preference' -f $LOG_LEVELS[$L]) -Value:(
    [System.Int32]::Parse([System.String]$LogLevel[$L]) -as [System.Management.Automation.ActionPreference]
  )
}

# Configure the debug levels: first digit ErrorActionPreference, second digit
# Set-PSDebug, third digit Set-StrictMode.
$ErrorActionPreference = [System.Management.Automation.ActionPreference][System.Int32]::Parse($DebugLevel.Substring(0, 1))
Switch ($DebugLevel.Substring(1, 1)) {
  '0' { Set-PSDebug -Off }
  '1' { Set-PSDebug -Trace:1 }
  '2' { Set-PSDebug -Trace:2 }
  '3' { Set-PSDebug -Trace:1 -Step }
  '4' { Set-PSDebug -Trace:2 -Step }
}
If ($DebugLevel.Substring(2, 1) -eq '0') {
  Set-StrictMode -Off
} Else {
  Set-StrictMode -Version:([System.String]$DebugLevel.Substring(2, 1))
}

# Universal trap used to help with debugging efforts. The original template's
# Wait-Debugger/Exit are interactive-host machinery; under the Ansible
# transport the trap logs and rethrows (Break) so the task fails honestly.
Trap {
  # The failure text is emitted FIRST and on its own. A bare `Throw '<string>'` leaves
  # InvocationInfo null on the inner ErrorRecord, and reaching into it under StrictMode raises a
  # property error that the surrounding Catch would swallow -- costing the operator the real
  # failure and printing 'diagnostics unavailable' in its place. Order is the whole fix.
  Try {
    Write-Warning -Message:(
      '[{0:0000}] {1} [{2}]' -f @(
        [System.Int64]$PSItem.InvocationInfo.ScriptLineNumber
        [System.String]$PSItem.Exception.Message
        [System.String]$PSItem.Exception.GetBaseException().GetType().FullName
      )
    )
  } Catch {
    Write-Warning -Message:'Trap could not render the failure text for this error record.'
  }

  # The invoking line is a nicety, attempted separately and null-guarded at every hop.
  Try {
    $Record = $PSItem.Exception.PSObject.Properties['ErrorRecord']
    If ($Null -ne $Record -and $Null -ne $Record.Value -and $Null -ne $Record.Value.InvocationInfo) {
      Write-Debug -Message:('Failed to execute command: {0}' -f [System.String]$Record.Value.InvocationInfo.Line)
    }
  } Catch {
    Write-Debug -Message:'Trap diagnostics unavailable for this error record.'
  }

  Break
}

# Under win_powershell the transport provides $Ansible; standalone (a dev
# shell or a Pester spec) it does not, so the script creates a faithful stub.
$StandaloneRun = $Null -eq (Get-Variable -Name:'Ansible' -ValueOnly -ErrorAction:'SilentlyContinue')
If ($StandaloneRun) {
  $Ansible = [PSCustomObject]@{
    Changed   = $True
    CheckMode = $False
    Failed    = $False
    Result    = $Null
  }
}

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

# A read never changes anything: a throw below must not inherit the transport's true.
$Ansible.Changed = $False

$Service = Get-CimInstance -ClassName:'Win32_Service' -Filter:("Name='{0}'" -f $ServiceName)
If (-not $Service) {
  Throw ('SQL service {0} is not installed on this host.' -f $ServiceName)
}
$Running = $Service.State -eq 'Running'

# The instance publishes its own directory name, which carries the product major version
# ('MSSQL16.MSSQLSERVER'). Composing that would be predicting a vendor's numbering.
# Looked up through PSObject rather than as .$InstanceName: this script runs under Set-StrictMode
# 3, where naming an absent property throws a StrictMode error and would make the diagnostic below
# unreachable on exactly the host that needs it.
$Registered = (Get-ItemProperty -LiteralPath:$InstanceNamesKey).PSObject.Properties[$InstanceName]
$Directory = If ($Registered) { [System.String]$Registered.Value } Else { '' }
If ([System.String]::IsNullOrWhiteSpace($Directory)) {
  $Known = (Get-ItemProperty -LiteralPath:$InstanceNamesKey).PSObject.Properties |
    Where-Object { $PSItem.Name -notlike 'PS*' } | ForEach-Object { $PSItem.Name }
  $KnownList = $Known -join ', '
  Throw ('SQL instance {0} is not registered on this host. Known instances: {1}' -f $InstanceName, $KnownList)
}

# Composed, so its existence is proven rather than assumed: the caller WRITES here, and the
# registry module creates a missing key, which would silently pin the paths where no engine reads.
# Formatted rather than Join-Path: Join-Path resolves the drive qualifier, so it demands a live
# HKLM: provider and cannot be exercised off Windows. A registry path's separator is always '\'.
$SettingsKey = '{0}\{1}\MSSQLServer' -f $InstanceRoot, $Directory
If (-not (Test-Path -LiteralPath:$SettingsKey)) {
  Throw ('SQL instance {0} has no settings key at {1}.' -f $InstanceName, $SettingsKey)
}

$EffectiveData = ''
$EffectiveLog = ''
$SusdbData = ''
$SusdbLog = ''
$SusdbFileCount = 0
$SusdbState = ''
$SusdbReadOnly = -1
If ($Running) {
  $Connection = New-Object -TypeName:'System.Data.SqlClient.SqlConnection' -ArgumentList:(
    'Server=.;Database=master;Integrated Security=true;Encrypt=false;'
  )
  $Connection.Open()
  Try {
    # One scalar per property rather than one row of two: a scalar is a value, where a reader is a
    # cursor whose lifetime has to be managed and whose column access is an indexer no stand-in can
    # offer. Both properties change only at startup, so reading them a millisecond apart cannot
    # disagree. The pair of round trips is on a local connection and costs nothing measurable.
    $DataCommand = $Connection.CreateCommand()
    $DataCommand.CommandText = "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(4000))"
    $EffectiveData = [System.String]$DataCommand.ExecuteScalar()

    $LogCommand = $Connection.CreateCommand()
    $LogCommand.CommandText = "SELECT CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(4000))"
    $EffectiveLog = [System.String]$LogCommand.ExecuteScalar()
    # TrimEnd because the engine reports a trailing separator and the registry does not; a
    # comparison that missed that would restart the instance on every converge.
    $EffectiveData = $EffectiveData.TrimEnd('\')
    $EffectiveLog = $EffectiveLog.TrimEnd('\')

    # Where the ENGINE has SUSDB's files, which is the only thing that proves the database is
    # attached FROM them. Files sitting at the expected paths prove nothing on their own: they
    # survive a detach, and a SUSDB attached from somewhere else leaves exactly that picture.
    # The catalog lists files for an OFFLINE database too, so attachment cannot answer whether
    # the database is serviceable; that is read separately, from sys.databases, below.
    # DB_ID returns null when no such database exists. The path queries then match no row and
    # ExecuteScalar returns null; the count query still returns one row carrying zero. Either
    # way these read empty and 0 -- a host that has not run post-installation yet.
    $SusdbSelect = "SELECT CAST(physical_name AS nvarchar(4000)) FROM sys.master_files"
    $SusdbWhere = "WHERE database_id = DB_ID('SUSDB')"

    $SusdbDataCommand = $Connection.CreateCommand()
    $SusdbDataCommand.CommandText = "$SusdbSelect $SusdbWhere AND type_desc = 'ROWS'"
    $SusdbData = [System.String]$SusdbDataCommand.ExecuteScalar()

    $SusdbLogCommand = $Connection.CreateCommand()
    $SusdbLogCommand.CommandText = "$SusdbSelect $SusdbWhere AND type_desc = 'LOG'"
    $SusdbLog = [System.String]$SusdbLogCommand.ExecuteScalar()

    # Counted as well as located, because the scalars above report the FIRST file of each kind.
    # A second data file on another volume would leave both of them reading correctly.
    $SusdbCountCommand = $Connection.CreateCommand()
    $SusdbCountCommand.CommandText = "SELECT COUNT(*) FROM sys.master_files $SusdbWhere"
    $SusdbFileCount = [System.Int32]$SusdbCountCommand.ExecuteScalar()

    # Whether the database can SERVE, which is a different question from where its files are. It
    # can be attached from the declared volume and still be RECOVERY_PENDING after an unclean stop,
    # or read-only after an ALTER, and post-installation would build on either. Empty and -1 when
    # no such database exists, which is what a first converge looks like.
    $SusdbStateCommand = $Connection.CreateCommand()
    $SusdbStateCommand.CommandText = "SELECT state_desc FROM sys.databases WHERE name = 'SUSDB'"
    $SusdbState = [System.String]$SusdbStateCommand.ExecuteScalar()

    If ($SusdbState) {
      $SusdbReadOnlyCommand = $Connection.CreateCommand()
      $SusdbReadOnlyCommand.CommandText =
      "SELECT CAST(is_read_only AS int) FROM sys.databases WHERE name = 'SUSDB'"
      $SusdbReadOnly = [System.Int32]$SusdbReadOnlyCommand.ExecuteScalar()
    }
  } Finally {
    $Connection.Close()
  }
}

$ServiceSid = (
  New-Object -TypeName:'System.Security.Principal.NTAccount' -ArgumentList:('NT SERVICE\{0}' -f $ServiceName)
).Translate([System.Security.Principal.SecurityIdentifier]).Value

# The identities a deny can block the engine through: its own, plus the well-known groups an
# NT SERVICE token carries. A grant must name the service itself; a deny need not.
$TokenSids = @(
  $ServiceSid
  'S-1-1-0'      # Everyone
  'S-1-5-6'      # NT AUTHORITY\SERVICE
  'S-1-5-11'     # NT AUTHORITY\Authenticated Users
  'S-1-5-15'     # NT AUTHORITY\This Organization
  'S-1-5-32-545' # BUILTIN\Users
  'S-1-5-80-0'   # NT SERVICE\ALL SERVICES
  'S-1-5-32-558' # BUILTIN\Performance Monitor Users
  'S-1-2-0'      # LOCAL
  'S-1-2-1'      # CONSOLE LOGON
)

$FullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
$Inheritable = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
$NoPropagation = [System.Security.AccessControl.PropagationFlags]::None

# Rules are fetched AS SIDs so a renamed or localised principal cannot satisfy the comparison by
# accident, and INHERITED rules are included because an inherited grant is a real grant.
# Collected positionally, never into a hashtable keyed by path: PowerShell hashtables are
# case-insensitive, so 'E:\MSSQL\Data' and 'e:\mssql\data' would collapse into one entry and
# report the log directory's access for both.
$Access = @()
ForEach ($Target In @($DesiredData, $DesiredLog)) {
  $Granted = $False
  $Denied = $False

  If (Test-Path -LiteralPath:$Target) {
    $Rules = (Get-Acl -LiteralPath:$Target).GetAccessRules(
      $True, $True, [System.Security.Principal.SecurityIdentifier]
    )
    $Denied = @($Rules | Where-Object {
        $PSItem.AccessControlType -eq 'Deny' -and
        $TokenSids -contains $PSItem.IdentityReference.Value -and
        ($PSItem.FileSystemRights -band $FullControl) -ne 0
      }).Count -gt 0
    $Granted = @($Rules | Where-Object {
        $PSItem.IdentityReference.Value -eq $ServiceSid -and
        $PSItem.AccessControlType -eq 'Allow' -and
        ($PSItem.FileSystemRights -band $FullControl) -eq $FullControl -and
        ($PSItem.InheritanceFlags -band $Inheritable) -eq $Inheritable -and
        $PSItem.PropagationFlags -eq $NoPropagation
      }).Count -gt 0
  }
  $Access += [PSCustomObject]@{ Granted = $Granted; Denied = $Denied }
}

$PlacementValid = $Running -and ($EffectiveData -ieq $DesiredData) -and ($EffectiveLog -ieq $DesiredLog)

$Result = [PSCustomObject]@{
  changed            = [System.Boolean]$False
  check_mode         = [System.Boolean]$Ansible.CheckMode
  data_acl_denied    = [System.Boolean]$Access[0].Denied
  data_acl_granted   = [System.Boolean]$Access[0].Granted
  effective_data     = [System.String]$EffectiveData
  effective_log      = [System.String]$EffectiveLog
  log_acl_denied     = [System.Boolean]$Access[1].Denied
  log_acl_granted    = [System.Boolean]$Access[1].Granted
  msg                = If (-not $Running) {
    'Instance {0} is {1}; placement cannot be read until it runs' -f $ServiceName, $Service.State
  } ElseIf ($PlacementValid) {
    'Instance {0} creates databases in {1}' -f $ServiceName, $EffectiveData
  } Else {
    'Instance {0} creates databases in {1}, not {2}' -f $ServiceName, $EffectiveData, $DesiredData
  }
  placement_read     = [System.Boolean]$Running
  placement_valid    = [System.Boolean]$PlacementValid
  service_sid        = [System.String]$ServiceSid
  service_start_mode = [System.String]$Service.StartMode
  service_state      = [System.String]$Service.State
  settings_key       = [System.String]$SettingsKey
  susdb_data_path    = [System.String]$SusdbData
  susdb_file_count   = [System.Int32]$SusdbFileCount
  susdb_log_path     = [System.String]$SusdbLog
  susdb_read_only    = [System.Int32]$SusdbReadOnly
  susdb_state        = [System.String]$SusdbState
}

#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result

If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:4
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #

#endregion --- [ Script ] -------------------------------------------------------------------- #
