#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Brings this server's update catalogue, and the files behind it, down from its upstream.

    .DESCRIPTION
        A server that knows where its upstream is has not yet spoken to it. Pointing at an upstream
        writes five values; it fetches nothing. Until a synchronisation completes, this server
        offers its clients an empty catalogue -- and a client that asks an empty server reports
        "no updates required" and looks exactly like success. That silence is what this exists to
        remove.

        TWO phases, because either alone leaves clients unable to install anything. The
        synchronisation brings the metadata and, on a replica, the upstream's approvals. The
        content download brings the bytes those approvals point at. A client offered an update
        whose file has not arrived downloads nothing, and with no route to Microsoft it has nowhere
        else to look.

        Idempotent on whether the server has EVER completed a synchronisation, not on how long ago.
        A downstream does not need to re-sync to be correct, and a role that synchronised on every
        converge would report changed forever. Force exists for the one case that rule misses: the
        upstream itself was just re-pointed, so the catalogue on disk came from somewhere else.

    .PARAMETER DebugLevel
        Three digits: ErrorActionPreference, Set-PSDebug, Set-StrictMode.

    .PARAMETER LogLevel
        Six digits, one per stream: Verbose, Debug, Information, Warning, Error, Fatal.

    .PARAMETER Force
        Synchronise even though one has already succeeded. The caller passes the upstream actor's
        own change report, so a re-pointed server refetches and a converged one does not.

    .PARAMETER ContentTimeoutSeconds
        How long to wait for the content download to finish after the metadata arrives.

    .PARAMETER Mode
        'wait' starts a synchronisation and does not return until the catalogue and the files
        behind it are down, or a deadline passes. 'start' starts one and returns.

        'start' exists because a first synchronisation against a full Microsoft mirror is measured
        in WEEKS. A converge cannot hold a step open that long, and an estate on that path still
        wants the work under way. What it buys is a server that is fetching; what it costs is that
        nothing here can say the catalogue arrived, because it has not.

        The in-flight stop below is done in BOTH modes. Starting underneath a running
        synchronisation throws, and that is true whether or not this intends to wait for its own.

    .PARAMETER TimeoutSeconds
        How long to wait for the synchronisation itself to reach a terminal state.

    .OUTPUTS
        One object carrying changed, check_mode, mode, msg, needing_files, result, started,
        update_count and waited. 'started' is whether this run began a synchronisation; 'waited'
        is whether it slept, in any mode -- polling an in-flight run to a stop counts.

        Deliberately NOT a downloaded byte count. GetContentDownloadProgress reports the updates
        currently DOWNLOADING, so by the time this has finished waiting it reads zero -- and a
        field that is structurally always zero is worse than no field, because a reader believes
        it.
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
  [ValidateRange(60, 21600)]
  [System.Int32]
  $ContentTimeoutSeconds,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $Force,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateRange(60, 21600)]
  [System.Int32]
  $TimeoutSeconds,

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateSet('wait', 'start')]
  [System.String]
  $Mode = 'wait'
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

# The transport seeds Changed true. Nothing is fetched yet, and a throw below must not report a
# change this run never made.
$Ansible.Changed = $False

$Server = Get-WsusServer
If ($Null -eq $Server) {
  Throw 'Get-WsusServer returned nothing; WSUS post-installation must complete before it can be told to synchronise.'
}

$Subscription = $Server.GetSubscription()

#region ------ [ Has this server ever spoken to its upstream ] ------------------------------- #
# GetLastSynchronizationInfo throws on a server that has never synchronised, so absence arrives as
# an exception rather than as a null. Caught and read as 'never', which is exactly what it means --
# letting it escape would turn a first run into a failure.
$Succeeded = $False
$LastResult = 'NeverRun'

Try {
  $Last = $Subscription.GetLastSynchronizationInfo()
  $LastResult = [System.String]$Last.Result
  $Succeeded = ($LastResult -eq 'Succeeded')
} Catch {
  # A server with no history and a server that could not answer both arrive here, and they mean
  # opposite things: the first should synchronise, the second should stop. Told apart
  # STRUCTURALLY rather than by matching a message, which would be a different string in a
  # different install language. An empty history is "never"; anything else rethrows, because
  # starting a synchronisation to paper over a database fault would hide the fault and report a
  # change.
  If (@($Subscription.GetSynchronizationHistory()).Count -gt 0) {
    Throw
  }

  $Succeeded = $False
  $LastResult = 'NeverRun'
}

# Force is the upstream actor's own change report. A server pointed somewhere new holds a catalogue
# from somewhere else, and "it synchronised once" is no longer an answer about the current source.
$NeedsSync = ($Force -or (-not $Succeeded))
#endregion --- [ Has this server ever spoken to its upstream ] ------------------------------- #

#region ------ [ The catalogue ] ------------------------------------------------------------- #
$Synchronised = $False
$Waited = $False
$Stopped = $False

If ($NeedsSync -and $PSCmdlet.ShouldProcess($Server.Name, 'Synchronise from the upstream WSUS server')) {
  # A synchronisation already running is not this one, and starting underneath it throws. Waiting
  # for it and then starting our own is what makes the result below ours to read.
  #
  # StopSynchronization is ASYNCHRONOUS. The server passes through Stopping on its way to
  # NotProcessing, and StartSynchronization throws for as long as it is there -- so asking it to
  # stop and starting in the next statement is a race this would lose on a busy server. Polled to
  # a full stop first, with the same deadline the synchronisation itself gets.
  If ([System.String]$Subscription.GetSynchronizationStatus() -ne 'NotProcessing') {
    $Subscription.StopSynchronization()
    $Stopped = $True

    $StopDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
    While (
      ((Get-Date) -lt $StopDeadline) -and
      ([System.String]$Subscription.GetSynchronizationStatus() -ne 'NotProcessing')
    ) {
      $Waited = $True
      Start-Sleep -Seconds 10
    }

    If ([System.String]$Subscription.GetSynchronizationStatus() -ne 'NotProcessing') {
      Throw (
        'A synchronisation was asked to stop and had not within {0} seconds; refusing to start one underneath it.' -f $TimeoutSeconds
      )
    }
  }

  $Subscription.StartSynchronization()

  # The host is changed from here: a synchronisation that starts has already begun writing a
  # catalogue, whether or not it finishes.
  $Ansible.Changed = $True
  $Synchronised = $True

  # START AND GO. Everything below this point reads a FINISHED synchronisation -- the terminal
  # status, the last result, the counts, the files behind them -- and none of it is answerable
  # about one still running. So this returns instead of reporting numbers it would have to invent.
  If ($Mode -eq 'start') {
    $StartedAfter = If ($Stopped) { ' after the previous one was stopped,' } Else { '' }
    $Ansible.Result = @{
      changed       = $True
      check_mode    = [System.Boolean]$Ansible.CheckMode
      mode          = 'start'
      msg           = ('Synchronisation started{0} and not waited for. This server is fetching; ' +
                       'whether it arrives is not known here.') -f $StartedAfter
      needing_files = -1
      result        = 'NotWaited'
      started       = $True
      update_count  = -1
      waited        = [System.Boolean]$Waited
    }

    Return
  }

  $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  Do {
    $Waited = $True
    Start-Sleep -Seconds 10
  } While (
    ((Get-Date) -lt $Deadline) -and
    ([System.String]$Subscription.GetSynchronizationStatus() -ne 'NotProcessing')
  )

  If ([System.String]$Subscription.GetSynchronizationStatus() -ne 'NotProcessing') {
    Throw (
      'The synchronisation from the upstream did not finish within {0} seconds; refusing to report a catalogue this server may not have.' -f $TimeoutSeconds
    )
  }

  # Terminal is not the same as successful. A synchronisation that stops having failed leaves the
  # server exactly as empty as one that never ran, and the difference is only visible here.
  $Last = $Subscription.GetLastSynchronizationInfo()
  $LastResult = [System.String]$Last.Result

  If ($LastResult -ne 'Succeeded') {
    Throw (
      'The synchronisation from the upstream ended {0} rather than Succeeded. This server has no catalogue to serve.' -f $LastResult
    )
  }
}
#endregion --- [ The catalogue ] ------------------------------------------------------------- #

#region ------ [ The bytes the catalogue points at ] ----------------------------------------- #
# Metadata without content is a server that offers updates it cannot deliver. On a replica the
# upstream's approvals arrive with the catalogue, so the download starts on its own -- what this
# waits for is its end.
#
# COMPLETENESS comes from UpdatesNeedingFilesCount, not from the byte counters.
# GetContentDownloadProgress reports the updates currently DOWNLOADING, so both of its counters
# read zero on a server that has finished, on a server that has not started, and on a server whose
# download failed -- three states with nothing in common. Waiting on it would return instantly
# from an empty queue and report a catalogue whose files never arrived. The byte counters are kept
# not read at all. Read after the wait they are zero every time, and a number that is always zero
# invites a reader to conclude something from it.
#
# UpdatesWithServerErrorsCount is checked too, because a download that will never succeed leaves
# UpdatesNeedingFilesCount above zero forever, and waiting the full deadline for it is a slow way
# to learn something the server already knows.
#
# Waited for on any run that synchronised, and on any run that still needs files: a previous run
# may have timed out here while the catalogue itself completed, leaving a server converged in
# metadata and useless in practice.
$Status = $Server.GetStatus()
$NeedingFiles = [System.Int32]$Status.UpdatesNeedingFilesCount
$ServerErrors = [System.Int32]$Status.UpdatesWithServerErrorsCount

# EVERY snapshot, not only the ones taken inside the wait. The two counts are independent: a server
# can report updates it cannot download while needing no files at all -- an update in Failed or
# LicenseAgreementFailed state is an error that is not outstanding work -- and a loop entered only
# when files are outstanding would never look. Checked before the wait, on every poll inside it,
# and therefore on the snapshot the wait exits with.
If ($ServerErrors -gt 0) {
  Throw (
    'The server reports {0} update(s) it cannot download. Waiting for content that will never arrive would only delay this.' -f $ServerErrors
  )
}

# start mode never waits for content, whatever the catalogue did: a server that already
# synchronised and still has files outstanding is reported as such, not slept on. 'waited' in
# the report means a sleep happened in this run, in any mode -- polling an in-flight run to a
# stop before starting another is one.
If (($Mode -eq 'wait') -and ($Synchronised -or ($NeedingFiles -gt 0)) -and
    $PSCmdlet.ShouldProcess($Server.Name, 'Wait for the update content to arrive')) {
  $ContentDeadline = (Get-Date).AddSeconds($ContentTimeoutSeconds)

  While (((Get-Date) -lt $ContentDeadline) -and ($NeedingFiles -gt 0)) {
    $Waited = $True
    Start-Sleep -Seconds 10
    $Status = $Server.GetStatus()
    $NeedingFiles = [System.Int32]$Status.UpdatesNeedingFilesCount
    $ServerErrors = [System.Int32]$Status.UpdatesWithServerErrorsCount

    If ($ServerErrors -gt 0) {
      Throw (
        'The server reports {0} update(s) it cannot download. Waiting for content that will never arrive would only delay this.' -f $ServerErrors
      )
    }
  }

  If ($NeedingFiles -gt 0) {
    Throw (
      'The update content did not finish downloading within {0} seconds; {1} update(s) still need files and a client offered them could not install them.' -f $ContentTimeoutSeconds, $NeedingFiles
    )
  }
}

#endregion --- [ The bytes the catalogue points at ] ----------------------------------------- #

# Reached by a wait-mode run, and by a start-mode run that had nothing to start: the last
# synchronisation already succeeded, so no start and no wait happened, and the report says so
# rather than claiming a mode the caller did not select.
$Result = [PSCustomObject]@{
  changed       = [System.Boolean]$NeedsSync
  check_mode    = [System.Boolean]$Ansible.CheckMode
  mode          = [System.String]$Mode
  msg           = 'synchronisation {0}, {1} updates, {2} still needing files' -f $LastResult, $Server.GetUpdateCount(), $NeedingFiles
  needing_files = [System.Int32]$NeedingFiles
  result        = [System.String]$LastResult
  started       = [System.Boolean]$Synchronised
  update_count  = [System.Int32]$Server.GetUpdateCount()
  waited        = [System.Boolean]$Waited
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
