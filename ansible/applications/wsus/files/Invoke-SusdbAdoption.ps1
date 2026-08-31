#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    .SYNOPSIS
        Attaches a preserved SUSDB to the local SQL Server instance, behind health gates.

    .DESCRIPTION
        A replaced operating system leaves the update database on its own volume while the
        completion flags that describe it are gone with the old root disk. WSUS reads only the
        flags, classifies the host as a fresh install, and its post-installation then tries to
        CREATE a database over files that already exist -- measured on this image 2026-08-27:
        'Install type is: Fresh', then 'Cannot create file ... because it already exists'. This
        script is what makes that host converge instead: it attaches the preserved pair FIRST, so
        post-installation finds a database and configures it rather than creating one.

        Attaching is the whole mutation. It is refused unless the caller's own classification says
        the database is absent from the engine and both files are present, because attaching over
        a database the engine already has, or from half a pair, are the two ways this could lose
        data rather than save it.

        ONE health gate runs after the attach, and it names the path it defends: the operating-
        system swap terminates an instance, so a database carried through an unclean stop can come
        back RECOVERY_PENDING or SUSPECT. A database that attaches but cannot serve is not an
        adoption, and leaving it attached would let post-installation build on it.

        There is no read-only, file-count or off-target gate. This lifecycle issues no ALTER that
        would mark a database read-only, never gives SUSDB a file beyond the pair post-installation
        creates, and reaches this script only when the engine holds no SUSDB at all -- so the files
        it reports afterwards are the two the attach named. Where the database ends up is proven
        for every converge, gated on nothing, by the role's own END attachment proof.

        Rollback detaches ONLY what this invocation attached. A database that was already there
        when the script started is never detached by a failure here, because this script is not
        what put it at risk. The detach is best-effort: it takes the database through EMERGENCY
        and SINGLE_USER first, which is what the engine's own limitations demand for a SUSPECT
        database, but a detach that still fails is reported as a warning and the original failure
        is what propagates. The run stops either way; what a failed rollback costs is a database
        left attached for an operator to deal with, not a silent success.

        Org scripts are a single straightforward process stage in the org script template's
        architecture: one [ Script ] region carrying [ Initialization ] (strict mode, transport
        detection, input normalization), [ Main ] (act -> build ONE result object), and
        [ Output ] (the same object to $Ansible or as JSON).

    .PARAMETER DebugLevel
        Three-digit control string configuring independent debugging functions, one digit each.
        First digit: ErrorActionPreference (0 SilentlyContinue, 1 Stop, 2 Continue, 3 Inquire,
        4 Ignore, 5 Suspend). Second digit: Set-PSDebug. Third digit: Set-StrictMode.

    .PARAMETER LogLevel
        Six-digit control string setting the preference for each stream, in the order Verbose,
        Debug, Information, Warning, Error, Fatal.

    .PARAMETER DataFile
        Full path of the preserved primary data file to attach.

    .PARAMETER LogFile
        Full path of the preserved log file to attach.

    .EXAMPLE
        .\Invoke-SusdbAdoption.ps1 -DataFile 'E:\MSSQL\Data\SUSDB.mdf' `
            -LogFile 'E:\MSSQL\Log\SUSDB_log.ldf'

    .OUTPUTS
        One object carrying adopted, attached_before, changed, check_mode, msg and state.

        adopted is true only when THIS invocation attached the database. attached_before says the
        engine already had it, in which case nothing is done and changed is false.
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
  [ValidatePattern('^[A-Za-z]:\\')]
  [System.String]
  $DataFile,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[A-Za-z]:\\')]
  [System.String]
  $LogFile
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

# The transport seeds Changed true. A throw below -- a refused connection, or a gate failure whose
# rollback already undid the attach -- must not inherit it and report a change that was undone or
# never made.
$Ansible.Changed = $False

$Adopted = $False
$AttachedBefore = $False
# Separate from $Adopted on purpose. $Adopted is what this invocation DID; $WouldAdopt is what the
# machine needs. Under the -WhatIf the transport injects they diverge, and reporting the deed would
# tell an operator running --check that a host which cannot converge needs nothing.
$WouldAdopt = $False
$State = ''

$Connection = New-Object -TypeName:'System.Data.SqlClient.SqlConnection' -ArgumentList:(
  'Server=.;Database=master;Integrated Security=true;Encrypt=false;'
)

# The startup race lives HERE rather than on the caller's task, because the caller's retry would
# repeat the mutation: an engine that answers but fails the health gate would be attached and
# rolled back once per attempt. Only opening the connection is retried, which is the only part
# the race can affect. The feature install one region up can ask for a reboot, and the restart
# that follows returns at the logon prompt before the auto-start services have finished.
$OpenAttempt = 0
While ($True) {
  $OpenAttempt++
  Try {
    $Connection.Open()
    Break
  } Catch {
    If ($OpenAttempt -ge 12) { Throw }
    Start-Sleep -Seconds:5
  }
}
Try {
  # Asked of sys.databases rather than sys.master_files: this is a question about the DATABASE
  # existing, and master_files answers about files, which is a different thing when neither is
  # there.
  $ExistsCommand = $Connection.CreateCommand()
  $ExistsCommand.CommandText = "SELECT COUNT(*) FROM sys.databases WHERE name = 'SUSDB'"
  $AttachedBefore = ([System.Int32]$ExistsCommand.ExecuteScalar()) -gt 0
  $WouldAdopt = -not $AttachedBefore

  If (-not $AttachedBefore) {
    # The one mutation. FOR ATTACH rather than FOR ATTACH_REBUILD_LOG, because a WSUS database
    # whose log is missing is not a database this script should quietly reconstruct -- the caller
    # classified a complete pair, and a missing log means that classification was wrong.
    If ($PSCmdlet.ShouldProcess('SUSDB', 'CREATE DATABASE ... FOR ATTACH')) {
      $AttachCommand = $Connection.CreateCommand()
      $AttachCommand.CommandText = @"
CREATE DATABASE SUSDB ON (FILENAME = N'$DataFile') LOG ON (FILENAME = N'$LogFile') FOR ATTACH
"@
      $Null = $AttachCommand.ExecuteNonQuery()
      $Adopted = $True
    }
  }

  # Everything after the attach sits inside this Catch, not just the gate. A failure while
  # READING the state is as much a reason to roll back as a failure of the state itself: either
  # way this invocation attached a database it cannot vouch for, and leaving it attached lets
  # post-installation build on it.
  Try {
    If ($AttachedBefore -or $Adopted) {
      $StateCommand = $Connection.CreateCommand()
      $StateCommand.CommandText = "SELECT state_desc FROM sys.databases WHERE name = 'SUSDB'"
      $State = [System.String]$StateCommand.ExecuteScalar()
    }

    # ONE gate, and it names the path it defends: the swap terminates an instance, so a database
    # carried through an unclean stop can come back RECOVERY_PENDING or SUSPECT. Attached but not
    # serviceable is the state post-installation must never build on.
    #
    # There is deliberately no read-only, file-count or off-target gate, and each is left out for
    # its own reason. A database-level read-only flag needs an ALTER this lifecycle never issues.
    # A SUSDB always has a data file and a log file, so a count below two is not a state that
    # exists. And nothing here ever gives SUSDB a third file -- post-installation creates the pair
    # and no later task adds to it -- so there is no file for an off-target check to find. Note
    # that attach CAN discover files from the primary's header rather than failing on them, so
    # the absence of that gate rests on this lifecycle, not on an invariant of SQL Server.
    If (($AttachedBefore -or $Adopted) -and ($State -ine 'ONLINE')) {
      Throw ('SUSDB attached but reports state {0}, not ONLINE' -f $State)
    }
  } Catch {
    # Only what THIS invocation attached is detached. A database that was already present is left
    # exactly as found: this script did not put it at risk and must not remove it.
    If ($Adopted) {
      Try {
        # EMERGENCY first, because sp_detach_db's documented limitations refuse a SUSPECT
        # database outright and demand emergency mode -- and SUSPECT is one of the two states
        # this gate exists to catch, so without it the rollback fails precisely when it is
        # needed. SINGLE_USER then takes the exclusive access the detach requires. Both are
        # no-ops in spirit on a database that is merely RECOVERY_PENDING.
        # skipchecks, because the default runs UPDATE STATISTICS on the way out and this database
        # is being detached precisely because it is not fit to be worked on. And the return code
        # is captured and raised: ExecuteNonQuery reports rows affected, never the procedure's
        # status, so a detach that failed would otherwise look like one that worked.
        $DetachCommand = $Connection.CreateCommand()
        $DetachCommand.CommandText =
        'ALTER DATABASE SUSDB SET EMERGENCY; ' +
        'ALTER DATABASE SUSDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE; ' +
        'DECLARE @DetachStatus int; ' +
        "EXEC @DetachStatus = sp_detach_db @dbname = N'SUSDB', @skipchecks = 'true'; " +
        "IF @DetachStatus <> 0 THROW 50000, 'sp_detach_db reported a non-zero status', 1;"
        $Null = $DetachCommand.ExecuteNonQuery()
      } Catch {
        Write-Warning -Message:('Rollback detach failed: {0}' -f $PSItem.Exception.Message)
      }
      $Adopted = $False
    }
    Throw
  }
} Finally {
  $Connection.Close()
}

$Result = [PSCustomObject]@{
  adopted         = [System.Boolean]$Adopted
  attached_before = [System.Boolean]$AttachedBefore
  changed         = [System.Boolean]$WouldAdopt
  check_mode      = [System.Boolean]$Ansible.CheckMode
  msg             = If ($Adopted) {
    'SUSDB attached from {0} and passed its health gates' -f $DataFile
  } ElseIf ($WouldAdopt) {
    'SUSDB would be attached from {0}' -f $DataFile
  } Else {
    'SUSDB was already attached; nothing to adopt'
  }
  state           = [System.String]$State
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
