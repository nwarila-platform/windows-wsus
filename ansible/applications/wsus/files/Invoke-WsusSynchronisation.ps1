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

    .PARAMETER TimeoutSeconds
        How long to wait for the synchronisation itself to reach a terminal state.

    .OUTPUTS
        One object carrying changed, check_mode, content_bytes, msg, result and update_count.
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
  $TimeoutSeconds
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
$LastResult = 'Never'

Try {
  $Last = $Subscription.GetLastSynchronizationInfo()
  $LastResult = [System.String]$Last.Result
  $Succeeded = ($LastResult -eq 'Succeeded')
} Catch {
  $Succeeded = $False
  $LastResult = 'Never'
}

# Force is the upstream actor's own change report. A server pointed somewhere new holds a catalogue
# from somewhere else, and "it synchronised once" is no longer an answer about the current source.
$NeedsSync = ($Force -or (-not $Succeeded))
#endregion --- [ Has this server ever spoken to its upstream ] ------------------------------- #

#region ------ [ The catalogue ] ------------------------------------------------------------- #
$Synchronised = $False

If ($NeedsSync -and $PSCmdlet.ShouldProcess($Server.Name, 'Synchronise from the upstream WSUS server')) {
  # A synchronisation already running is not this one, and starting underneath it throws. Waiting
  # for it and then starting our own is what makes the result below ours to read.
  If ([System.String]$Subscription.GetSynchronizationStatus() -ne 'NotProcessing') {
    $Subscription.StopSynchronization()
  }

  $Subscription.StartSynchronization()

  # The host is changed from here: a synchronisation that starts has already begun writing a
  # catalogue, whether or not it finishes.
  $Ansible.Changed = $True
  $Synchronised = $True

  $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  Do {
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
# Waited for on any run that synchronised, and on any run that finds bytes still outstanding: a
# previous run may have timed out here while the catalogue itself was complete, and that server is
# converged in metadata and useless in practice.
$Progress = $Server.GetContentDownloadProgress()
$Outstanding = ([System.Int64]$Progress.TotalBytesToDownload - [System.Int64]$Progress.DownloadedBytes)

If (($Synchronised -or ($Outstanding -gt 0)) -and $PSCmdlet.ShouldProcess($Server.Name, 'Wait for the update content to arrive')) {
  $ContentDeadline = (Get-Date).AddSeconds($ContentTimeoutSeconds)

  While (((Get-Date) -lt $ContentDeadline) -and ($Outstanding -gt 0)) {
    Start-Sleep -Seconds 10
    $Progress = $Server.GetContentDownloadProgress()
    $Outstanding = ([System.Int64]$Progress.TotalBytesToDownload - [System.Int64]$Progress.DownloadedBytes)
  }

  If ($Outstanding -gt 0) {
    Throw (
      'The update content did not finish downloading within {0} seconds; {1} bytes are still outstanding and a client offered these updates could not install them.' -f $ContentTimeoutSeconds, $Outstanding
    )
  }
}
#endregion --- [ The bytes the catalogue points at ] ----------------------------------------- #

$Result = [PSCustomObject]@{
  changed       = [System.Boolean]$NeedsSync
  check_mode    = [System.Boolean]$Ansible.CheckMode
  content_bytes = [System.Int64]$Progress.DownloadedBytes
  msg           = 'synchronisation {0}, {1} updates, {2} bytes of content' -f $LastResult, $Server.GetUpdateCount(), $Progress.DownloadedBytes
  result        = [System.String]$LastResult
  update_count  = [System.Int32]$Server.GetUpdateCount()
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
