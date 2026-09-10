#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Makes this WSUS server serve its clients over HTTPS with one pinned certificate.

    .DESCRIPTION
        Three things have to be true together before a client can talk to WSUS over TLS, and any
        one of them alone produces a server that looks configured and is not:

          the certificate is attached to the HTTPS listener, or the port answers with nothing to
          present;

          the client-facing virtual directories require SSL, or they keep answering over plain
          HTTP and the encryption is optional in practice;

          WSUS itself records that it is using SSL, or it keeps handing clients an http:// URL for
          its own endpoints and they leave the encrypted channel on their next call.

        So this writes all three and verifies all three. Measured on the target: WSUS creates the
        :8531: binding at install with no certificate on it, so the listener is reconciled rather
        than created -- there is nothing here that adds or removes a binding.

        Idempotent on the STATE, not the act. Every step is skipped when it is already true, which
        is what lets the run report no change on a converged host rather than re-attaching the same
        certificate and re-running wsusutil on every converge.

        The certificate is named by thumbprint rather than found by subject. A subject search picks
        whichever certificate happens to match, including one an operator left behind; the
        thumbprint pins the exact bytes the caller delivered, and the script refuses to bind
        anything else.

    .PARAMETER DebugLevel
        Three digits: ErrorActionPreference, Set-PSDebug, Set-StrictMode.

    .PARAMETER LogLevel
        Six digits, one per stream: Verbose, Debug, Information, Warning, Error, Fatal.

    .PARAMETER DnsName
        The name clients reach this server by, and the name WSUS records as its own. It has to be
        a name the pinned certificate is valid for, or every client rejects the listener.

    .PARAMETER Port
        The HTTPS port WSUS listens on. 8531 on a default installation.

    .PARAMETER SecuredPath
        The virtual directories that must require SSL, as site-relative paths. Vendor-fixed rather
        than a preference: these are the endpoints a client authenticates and reports through.

        Deliberately NOT every directory under the site. Content and SelfUpdate serve unencrypted
        by design, and requiring SSL on them breaks content delivery and legacy self-update;
        Reporting and Inventory are not endpoints the vendor asks to be secured. Taking the list
        from the caller rather than enumerating the site is what makes this indifferent to which
        of those a given image ships -- SelfUpdate, measured, is present at RTM and gone on a
        patched image.

    .PARAMETER SiteName
        The IIS site WSUS installed. 'WSUS Administration' on a default installation; WSUS builds
        its own site rather than living under Default Web Site.

    .PARAMETER Thumbprint
        The certificate to bind, as its forty hexadecimal characters. Pinned by the caller so the
        binding follows the exact certificate that was delivered.

    .PARAMETER WsusUtilPath
        Full path to wsusutil.exe, which is the only supported way to tell WSUS its own URL.

    .OUTPUTS
        One object carrying changed, check_mode, msg, bound, secured, ssl_enabled and thumbprint,
        each read back from the host after any write.
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
  $DnsName,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateRange(1, 65535)]
  [System.Int32]
  $Port,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String[]]
  $SecuredPath,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $SiteName,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[0-9A-Fa-f]{40}$')]
  [System.String]
  $Thumbprint,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $WsusUtilPath
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

# Tracks whether a write actually ran. Check mode arrives as -WhatIf, which suppresses the writes
# while leaving the drift flags true, so the verification below is gated on this rather than on
# the flags -- gating on the flags would verify a host nothing was written to.
$Wrote = $False

$Wanted = $Thumbprint.Trim().ToUpperInvariant()

# Normalised ONCE, here, and used for every comparison, for ShouldProcess, for wsusutil and for the
# verification below. wsusutil records the name without the padding it was handed, so a padded input
# compared against the recorded name never matches and re-runs wsusutil on every converge forever.
$WantedName = $DnsName.Trim()

# The IIS: drive does not exist until WebAdministration is loaded, and a provider path on a drive
# that does not exist fails as 'drive not found'. Under -ErrorAction SilentlyContinue that failure
# is indistinguishable from 'nothing is bound' -- the script would decide the listener is empty and
# then throw on the write. Loaded explicitly, and with -ErrorAction Stop, because every read below
# is only meaningful once it has succeeded.
Import-Module -Name:'WebAdministration' -ErrorAction:'Stop'

#region ------ [ The certificate this listener will present ] -------------------------------- #
# Refused rather than assumed. The certificate is delivered from outside this role, so a failed
# delivery or a key-less import is an input failure, and a listener bound to nothing answers the
# port and is rejected by every client -- far harder to read than a refusal naming the thumbprint.
$Certificate = Get-Item -Path:('Cert:\LocalMachine\My\{0}' -f $Wanted) -ErrorAction:'SilentlyContinue'
If ($Null -eq $Certificate) {
  Throw (
    'No certificate with thumbprint {0} is in LocalMachine\My. Its delivery and import have to succeed before the listener can be bound.' -f $Wanted
  )
}

If (-not $Certificate.HasPrivateKey) {
  Throw (
    'The certificate {0} is in LocalMachine\My without its private key, and TLS cannot be served from a certificate whose key is missing.' -f $Wanted
  )
}

# Expiry is the one property two clean runs cannot catch: an expired certificate stays bound and
# reads as converged on every subsequent run while every client rejects the listener. Everything
# else about this certificate -- its name, its key usage -- is fixed by the thumbprint the caller
# pinned, so it is not re-proven here.
If ($Certificate.NotAfter -lt (Get-Date)) {
  Throw (
    'The certificate {0} expired on {1:u}; refusing to bind a listener that every client will reject.' -f $Wanted, $Certificate.NotAfter
  )
}
#endregion --- [ The certificate this listener will present ] -------------------------------- #

#region ------ [ The HTTPS listener ] -------------------------------------------------------- #
# Measured on the target: WSUS creates the :8531: binding at install with no certificate attached,
# so this attaches one and never adds or removes a binding. A wrong certificate is removed first --
# the provider will not replace an existing entry in place, and leaving it binds the old one
# forever.
# The certificate mapping this script writes belongs to HTTP.SYS, and HTTP.SYS will happily hold a
# mapping for a port no site listens on. Without this the script would attach a certificate to
# 0.0.0.0:<port>, verify its own write, report success, and leave nothing serving -- so the site's
# own binding is required first. Refused rather than created: WSUS ships the :8531: binding at
# install, so its absence means the port is not the one this installation serves, which is a
# declaration to correct rather than a listener for this role to invent.
$SiteBinding = @(
  Get-WebBinding -Name:$SiteName -Protocol:'https' -Port:$Port -ErrorAction:'SilentlyContinue'
)
If ($SiteBinding.Count -eq 0) {
  Throw (
    'The site [{0}] has no https binding on port {1}. WSUS creates its own at install, so declaring a port it does not serve would attach a certificate to a listener nothing answers on.' -f $SiteName, $Port
  )
}

$SslPath = 'IIS:\SslBindings\0.0.0.0!{0}' -f $Port
$BoundBefore = Get-Item -Path:$SslPath -ErrorAction:'SilentlyContinue'

$BoundThumbprint = ''
If ($Null -ne $BoundBefore) {
  $BoundThumbprint = ([System.String]$BoundBefore.Thumbprint).Trim().ToUpperInvariant()
}

$NeedsBinding = ($BoundThumbprint -ne $Wanted)

If ($NeedsBinding -and $PSCmdlet.ShouldProcess($SslPath, 'Attach the pinned certificate to the HTTPS listener')) {
  If ($Null -ne $BoundBefore) {
    Remove-Item -Path:$SslPath -Force
  }

  $Null = New-Item -Path:$SslPath -Value:$Certificate
  $Ansible.Changed = $True
  $Wrote = $True
}
#endregion --- [ The HTTPS listener ] -------------------------------------------------------- #

#region ------ [ The directories that must refuse plain HTTP ] ------------------------------- #
# Read through Get-WebConfiguration rather than Get-WebConfigurationProperty. Measured on the
# target: once the flag is set, the property cmdlet returns an object whose Value is NULL, so a
# role comparing that against 'Ssl' finds drift on every converge and rewrites a setting that was
# already correct. Get-WebConfiguration reports '' when off and 'Ssl' when on, in both states.
#
# The token is matched rather than compared whole, because sslFlags is a flag list and a site that
# also carries Ssl128 reads 'Ssl,Ssl128' -- which requires SSL exactly as much as 'Ssl' does.
$NeedsSecuring = [System.Collections.Generic.List[System.String]]::new()
$Secured = [System.Collections.Generic.List[System.String]]::new()

# Only what THIS run turns on. Putting back a directory that was already requiring SSL would be a
# regression dressed as a rollback.
$SecuredThisRun = [System.Collections.Generic.List[System.String]]::new()

# What each of those carried BEFORE. A rollback that writes 'None' flattens a directory that was
# carrying, say, Ssl128 -- so the exact prior value is kept and put back.
$PriorFlags = @{}
$PriorValue = @{}

ForEach ($Directory In $SecuredPath) {
  $Location = '{0}/{1}' -f $SiteName, $Directory.Trim('/')
  $Access = Get-WebConfiguration -Filter:'system.webServer/security/access' -PSPath:'IIS:\' -Location:$Location

  $PriorValue[$Location] = [System.String]$Access.sslFlags

  If (([System.String]$Access.sslFlags) -match '(^|,)\s*Ssl\s*(,|$)') {
    $Secured.Add($Location)
  } Else {
    $NeedsSecuring.Add($Location)
  }
}

ForEach ($Location In $NeedsSecuring) {
  If ($PSCmdlet.ShouldProcess($Location, 'Require SSL')) {
    Set-WebConfigurationProperty -Filter:'system.webServer/security/access' -Name:'sslFlags' -PSPath:'IIS:\' -Location:$Location -Value:'Ssl'
    $SecuredThisRun.Add($Location)
    $PriorFlags[$Location] = $PriorValue[$Location]
    $Ansible.Changed = $True
    $Wrote = $True
  }
}
#endregion --- [ The directories that must refuse plain HTTP ] ------------------------------- #

#region ------ [ What WSUS tells its own clients ] ------------------------------------------- #
# Last of the three deliberately. wsusutil validates the SSL configuration it is recording, so it
# runs once the listener holds a certificate and the directories require it -- the vendor's own
# order, and the one where a failure means what it says.
#
# Every property is read through PSObject.Properties: ServerCertificateName does not exist on a
# server that has never been configured for SSL, and StrictMode turns a plain dereference of a
# missing property into an error about the property rather than an answer about the server.
$Setup = Get-ItemProperty -Path:'HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup' -ErrorAction:'SilentlyContinue'
If ($Null -eq $Setup) {
  Throw 'The WSUS Setup key is absent; post-installation must complete before the server can be told its own URL.'
}

$UsingSsl = $False
$UsingSslProperty = $Setup.PSObject.Properties['UsingSSL']
If ($Null -ne $UsingSslProperty) {
  $UsingSsl = ([System.Int32]$UsingSslProperty.Value -eq 1)
}

$RecordedName = ''
$RecordedNameProperty = $Setup.PSObject.Properties['ServerCertificateName']
If ($Null -ne $RecordedNameProperty) {
  $RecordedName = ([System.String]$RecordedNameProperty.Value).Trim()
}

$NeedsRecording = (
  (-not $UsingSsl) -or
  (($RecordedName.Length -gt 0) -and ($RecordedName -ne $WantedName))
)

# The rollback exists for ONE state, and it is the state that cannot fix itself. Between the
# directories requiring SSL and wsusutil persisting UsingSSL=1, the WSUS API is reachable over
# neither scheme: HTTP is refused by the directories this run just secured, and nothing yet tells
# the API to try HTTPS. A host left there cannot converge again, because every later run's first
# act is to read that API. So a failure here puts back exactly what this run turned on -- never
# what was already on, which would be a regression dressed as a rollback -- and then reports the
# original failure rather than the rollback.
If ($NeedsRecording -and $PSCmdlet.ShouldProcess($WantedName, 'Record the SSL name WSUS hands its clients')) {
  Try {
    $Run = Start-Process -FilePath:$WsusUtilPath -ArgumentList:@('configuressl', $WantedName) -Wait -NoNewWindow -PassThru

    # The host is touched from here whatever the exit code says, and whatever the rollback below
    # puts back: wsusutil was invoked, and a run that ends saying it changed nothing would be
    # lying about a server it ran a configuration tool against.
    $Ansible.Changed = $True
    $Wrote = $True

    If ($Run.ExitCode -ne 0) {
      Throw ('wsusutil configuressl {0} exited {1}; WSUS is still handing its clients the old URL.' -f $WantedName, $Run.ExitCode)
    }

    # The proof belongs INSIDE the protected interval, not after it. An exit code is wsusutil's
    # opinion; the registry is the server's, and a wsusutil that exits zero having persisted
    # nothing leaves precisely the state this rollback exists for. Proving it out here would have
    # thrown with the directories already secured and the rollback out of scope.
    $Persisted = Get-ItemProperty -Path:'HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup' -ErrorAction:'SilentlyContinue'
    $PersistedSsl = $False
    If ($Null -ne $Persisted) {
      $PersistedSslProperty = $Persisted.PSObject.Properties['UsingSSL']
      If ($Null -ne $PersistedSslProperty) {
        $PersistedSsl = ([System.Int32]$PersistedSslProperty.Value -eq 1)
      }
    }

    If (-not $PersistedSsl) {
      Throw 'WSUS still records itself as serving plain HTTP after wsusutil was told otherwise.'
    }

    $PersistedName = ''
    If ($Null -ne $Persisted) {
      $PersistedNameProperty = $Persisted.PSObject.Properties['ServerCertificateName']
      If ($Null -ne $PersistedNameProperty) {
        $PersistedName = ([System.String]$PersistedNameProperty.Value).Trim()
      }
    }

    If (($PersistedName.Length -gt 0) -and ($PersistedName -ne $WantedName)) {
      Throw (
        'WSUS records [{0}] as the name it hands its clients, not [{1}], after wsusutil exited zero.' -f $PersistedName, $WantedName
      )
    }
  } Catch {
    # Captured before anything else runs, so the rollback cannot overwrite the automatic variable
    # the rethrow depends on.
    $Original = $PSItem

    ForEach ($Location In $SecuredThisRun) {
      # Best effort, and deliberately not allowed to mask the real failure: a rollback that throws
      # would replace the operator's diagnosis with its own. Write-Warning is wrapped too, because
      # a caller running with a terminating warning preference would otherwise throw from the
      # diagnostic rather than from the fault.
      # An absent prior value means the directory was simply off, and 'None' is how IIS spells
      # that -- writing back the empty string the read returns is not the same thing. A prior
      # value that WAS set, 'Ssl128' say, is restored exactly rather than flattened to off.
      $Restore = 'None'
      If (-not [System.String]::IsNullOrEmpty($PriorFlags[$Location])) {
        $Restore = $PriorFlags[$Location]
      }

      Try {
        Set-WebConfigurationProperty -Filter:'system.webServer/security/access' -Name:'sslFlags' -PSPath:'IIS:\' -Location:$Location -Value:$Restore
      } Catch {
        Try {
          Write-Warning -Message:(
            'Could not put {0} back to accepting plain HTTP; the WSUS API may be unreachable until it is.' -f $Location
          ) -WarningAction:'Continue'
        } Catch {
          $Null = $PSItem
        }
      }
    }

    Throw $Original
  }
}
#endregion --- [ What WSUS tells its own clients ] ------------------------------------------- #

#region ------ [ Prove the host kept all three ] --------------------------------------------- #
# Each of the three is written through a different mechanism, and any one of them silently not
# persisting leaves a server that reads as configured and refuses its clients. They are re-read
# from the host rather than inferred from the writes above.
If ($Wrote) {
  $BoundAfter = Get-Item -Path:$SslPath -ErrorAction:'SilentlyContinue'
  $BoundAfterThumbprint = ''
  If ($Null -ne $BoundAfter) {
    $BoundAfterThumbprint = ([System.String]$BoundAfter.Thumbprint).Trim().ToUpperInvariant()
  }

  If ($BoundAfterThumbprint -ne $Wanted) {
    Throw (
      'The HTTPS listener on port {0} did not keep the pinned certificate. It now presents [{1}].' -f $Port, $BoundAfterThumbprint
    )
  }

  ForEach ($Directory In $SecuredPath) {
    $Location = '{0}/{1}' -f $SiteName, $Directory.Trim('/')
    $Access = Get-WebConfiguration -Filter:'system.webServer/security/access' -PSPath:'IIS:\' -Location:$Location

    If (([System.String]$Access.sslFlags) -notmatch '(^|,)\s*Ssl\s*(,|$)') {
      Throw ('{0} does not require SSL after being told to; it reports [{1}].' -f $Location, $Access.sslFlags)
    }
  }

  # What WSUS records for itself is deliberately NOT re-proven here. It is proven inside the
  # protected interval above, where a failure can still put the directories back -- proving it out
  # here would throw with them secured and the rollback out of scope, which is the one state that
  # cannot fix itself.
  If ($NeedsRecording) {
    $UsingSsl = $True
  }
  $Secured = [System.Collections.Generic.List[System.String]]::new()
  ForEach ($Directory In $SecuredPath) {
    $Secured.Add(('{0}/{1}' -f $SiteName, $Directory.Trim('/')))
  }
}
#endregion --- [ Prove the host kept all three ] --------------------------------------------- #

$Result = [PSCustomObject]@{
  bound       = [System.Boolean](-not $NeedsBinding -or $Wrote)
  changed     = [System.Boolean]($NeedsBinding -or ($NeedsSecuring.Count -gt 0) -or $NeedsRecording)
  check_mode  = [System.Boolean]$Ansible.CheckMode
  msg         = 'https://{0}:{1} presenting {2}' -f $WantedName, $Port, $Wanted
  secured     = [System.String[]]$Secured.ToArray()
  ssl_enabled = [System.Boolean]$UsingSsl
  thumbprint  = [System.String]$Wanted
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
