#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Points this WSUS server at an upstream server instead of Microsoft Update.

    .DESCRIPTION
        Five values move together and none of them is meaningful alone. SyncFromMicrosoftUpdate
        must go false, or the upstream name is recorded and ignored. The name, the port and the
        SSL flag decide which endpoint is contacted. And IsReplicaServer decides whether this
        server inherits the upstream's approvals or manages its own -- a replica mirrors the
        upstream's product selection AND its approvals, so an update approved upstream arrives
        approved here.

        The write is refused while a synchronisation is running. WSUS will accept the
        configuration change mid-sync and then behave unpredictably, because the sync in flight is
        still talking to the OLD source. The in-flight sync is stopped first and the stop is
        waited on; if it will not stop, this refuses rather than saving underneath it.

        After Save() the configuration is re-read from a freshly acquired handle. The
        configuration object is a client-side cache: it reports back whatever was assigned to it
        whether or not the server kept it, so verifying the object this script wrote through would
        prove nothing.

    .PARAMETER DebugLevel
        Three digits: ErrorActionPreference, Set-PSDebug, Set-StrictMode.

    .PARAMETER LogLevel
        Six digits, one per stream: Verbose, Debug, Information, Warning, Error, Fatal.

    .PARAMETER UpstreamUrl
        The upstream WSUS server as a URL, with scheme, host and an EXPLICIT port --
        'http://wsus.example.com:8530'. Required and never defaulted: pointing a downstream at the
        wrong source is worse than pointing it at nothing.

        One value rather than three because the three are never independently true: a host without
        its port names nothing dialable, and a scheme that disagrees with the port is a
        misconfiguration this shape cannot express. It is also the one place the boolean could go
        wrong -- an SSL flag crossing the Ansible boundary as the string 'False' binds to
        [System.Boolean] as TRUE, because every non-empty string casts true. A scheme cannot do
        that.

        The port must be written out. [System.Uri] supplies 80 or 443 when one is omitted, so a
        URL without a port silently names an endpoint the caller never chose. Written out, any
        port in range is accepted -- including 80 and 443. Which port is sensible is the
        operator's business; this refuses only the port nobody typed.

    .PARAMETER Replica
        True mirrors the upstream's selections and approvals; false manages approvals locally.

    .OUTPUTS
        One object carrying changed, check_mode, msg, replica, ssl, upstream and port, each read
        back from the server after any write.
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
  $UpstreamUrl,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $Replica
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

# The transport seeds Changed true. Nothing is written yet, and a throw below must not report a
# change this run never made.
$Ansible.Changed = $False

# The URL is taken apart here and the three values below are what the API actually wants. Parsed
# rather than pattern-matched because [System.Uri] is the same parser the rest of .NET uses, and a
# regex of my own would disagree with it at some edge nobody would find until it mattered.
$Uri = $Null
If (-not [System.Uri]::TryCreate($UpstreamUrl.Trim(), [System.UriKind]::Absolute, [Ref]$Uri)) {
  Throw "The upstream URL '$UpstreamUrl' is not an absolute URL. Expected scheme, host and port -- 'http://wsus.example.com:8530'."
}

$Scheme = $Uri.Scheme.ToLowerInvariant()
If ($Scheme -ne 'http' -and $Scheme -ne 'https') {
  Throw "The upstream URL '$UpstreamUrl' uses scheme '$Scheme'. WSUS is reached over http or https and nothing else."
}

# The port has to be WRITTEN, because [System.Uri] invents 80 or 443 when it is not and the caller
# would never know which endpoint was configured. IsDefaultPort cannot be used to detect that: it
# is equally true for a URL that omitted the port and one that spelled out 80. Only the text says
# which happened, so the text is what is checked.
#
# An explicitly written 80 or 443 is ACCEPTED. Whether WSUS is sensibly reached there is the
# operator's business, not this script's -- the technical limits are the range, checked upstream
# of here, and the scheme, checked above.
If ($UpstreamUrl.Trim() -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*:[0-9]+(?:[/?#]|$)') {
  Throw "The upstream URL '$UpstreamUrl' names no port, and one will not be guessed -- write it out, as in 'http://wsus.example.com:8530'."
}

$Wanted = $Uri.Host
$UpstreamPort = $Uri.Port
$UseSsl = ($Scheme -eq 'https')

# [System.Uri] refuses anything above 65535 and anything negative, but it accepts 0, which cannot
# be dialled. The parameter binder used to catch that with ValidateRange when the port arrived as
# its own argument; it arrives inside a URL now, so the range is checked here instead. Range is a
# technical limit and stays enforced -- WHICH port in that range is the operator's business.
If ($UpstreamPort -lt 1) {
  Throw "The upstream URL '$UpstreamUrl' names port $UpstreamPort. A port has to be between 1 and 65535 to be dialled."
}

If ([System.String]::IsNullOrWhiteSpace($Wanted)) {
  Throw 'An upstream server is required for a downstream topology and is deliberately never defaulted.'
}

$Server = Get-WsusServer
If ($Null -eq $Server) {
  Throw 'Get-WsusServer returned nothing; WSUS post-installation must complete before its source can be set.'
}

$Configuration = $Server.GetConfiguration()

# All five, because each alone leaves the server pointed somewhere it was not asked to point.
$NeedsChange = (
  $Configuration.SyncFromMicrosoftUpdate -or
  ($Configuration.UpstreamWsusServerName -ne $Wanted) -or
  ($Configuration.UpstreamWsusServerPortNumber -ne $UpstreamPort) -or
  ($Configuration.UpstreamWsusServerUseSsl -ne $UseSsl) -or
  ($Configuration.IsReplicaServer -ne $Replica)
)

If ($NeedsChange -and $PSCmdlet.ShouldProcess($Wanted, 'Set the upstream WSUS source')) {
  # A synchronisation in flight is still talking to the OLD source. Saving underneath it leaves
  # the server in a state neither configuration describes.
  $Subscription = $Server.GetSubscription()
  If ([System.String]$Subscription.GetSynchronizationStatus() -ne 'NotProcessing') {
    $Subscription.StopSynchronization()
    $Deadline = (Get-Date).AddSeconds(60)
    Do {
      Start-Sleep -Seconds 2
    } While (((Get-Date) -lt $Deadline) -and ([System.String]$Subscription.GetSynchronizationStatus() -ne 'NotProcessing'))

    If ([System.String]$Subscription.GetSynchronizationStatus() -ne 'NotProcessing') {
      Throw 'A synchronisation is running and would not stop within 60 seconds; refusing to change the source underneath it.'
    }
  }

  $Configuration.SyncFromMicrosoftUpdate = $False
  $Configuration.UpstreamWsusServerName = $Wanted
  $Configuration.UpstreamWsusServerPortNumber = $UpstreamPort
  $Configuration.UpstreamWsusServerUseSsl = $UseSsl
  $Configuration.IsReplicaServer = $Replica
  $Configuration.Save()

  # The host is changed from here, and the verification below can still throw.
  $Ansible.Changed = $True

  $Configuration = $Server.GetConfiguration()

  $StillDrifted = (
    $Configuration.SyncFromMicrosoftUpdate -or
    ($Configuration.UpstreamWsusServerName -ne $Wanted) -or
    ($Configuration.UpstreamWsusServerPortNumber -ne $UpstreamPort) -or
    ($Configuration.UpstreamWsusServerUseSsl -ne $UseSsl) -or
    ($Configuration.IsReplicaServer -ne $Replica)
  )

  If ($StillDrifted) {
    Throw (
      'The upstream source did not persist. Server reports microsoftUpdate={0} upstream=[{1}]:{2} ssl={3} replica={4}' -f
      $Configuration.SyncFromMicrosoftUpdate, $Configuration.UpstreamWsusServerName,
      $Configuration.UpstreamWsusServerPortNumber, $Configuration.UpstreamWsusServerUseSsl,
      $Configuration.IsReplicaServer
    )
  }
}

$Result = [PSCustomObject]@{
  changed    = [System.Boolean]$NeedsChange
  check_mode = [System.Boolean]$Ansible.CheckMode
  msg        = 'upstream [{0}]:{1} ssl={2} replica={3}' -f $Configuration.UpstreamWsusServerName, $Configuration.UpstreamWsusServerPortNumber, $Configuration.UpstreamWsusServerUseSsl, $Configuration.IsReplicaServer
  port       = [System.Int32]$Configuration.UpstreamWsusServerPortNumber
  replica    = [System.Boolean]$Configuration.IsReplicaServer
  ssl        = [System.Boolean]$Configuration.UpstreamWsusServerUseSsl
  upstream   = [System.String]$Configuration.UpstreamWsusServerName
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
