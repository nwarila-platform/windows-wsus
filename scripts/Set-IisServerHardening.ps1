#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Applies the server-level IIS and ASP.NET settings owned by the WSUS role.

    .DESCRIPTION
        Reads five IIS settings, compares them with the declared values, and writes only drift.
        The request-size limit is written through ServerManager so a default-equivalent value is
        explicit in applicationHost.config.

        Every write is guarded by ShouldProcess. Check mode therefore reports required changes
        without changing IIS.

    .PARAMETER DebugLevel
        Three digits: ErrorActionPreference, Set-PSDebug, Set-StrictMode.

    .PARAMETER LogLevel
        Six digits, one per stream: Verbose, Debug, Information, Warning, Error, Fatal.

    .PARAMETER MachineKeyValidation
        Validation algorithm for the .NET 4 machine key.

    .PARAMETER SessionTimeout
        Positive invariant-culture TimeSpan for ASP.NET session state.

    .PARAMETER AllowHighBitCharacters
        Whether IIS request filtering accepts high-bit characters.

    .PARAMETER MaxAllowedContentLength
        Explicit maximum request content length in bytes.

    .PARAMETER RemoveResponseHeader
        Server-level custom response header to remove.

    .EXAMPLE
        Set-IisServerHardening.ps1 -MachineKeyValidation 'HMACSHA256' `
          -SessionTimeout '00:15:00' -AllowHighBitCharacters $false `
          -MaxAllowedContentLength 30000000 -RemoveResponseHeader 'X-Powered-By'

    .OUTPUTS
        One object carrying changed, settings and msg.
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
  [System.String]
  $MachineKeyValidation,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $SessionTimeout,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.Boolean]
  $AllowHighBitCharacters,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.UInt32]
  $MaxAllowedContentLength,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [System.String]
  $RemoveResponseHeader
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

# The module injects -WhatIf in check mode. Reads must still run, and setup must not be
# suppressed.
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
    [System.Int32]::Parse([System.String]$LogLevel[$L]) -as
    [System.Management.Automation.ActionPreference]
  )
}

# Configure the debug levels: first digit ErrorActionPreference, second digit
# Set-PSDebug, third digit Set-StrictMode.
$ErrorActionPreference = [System.Management.Automation.ActionPreference][System.Int32]::Parse(
  $DebugLevel.Substring(0, 1)
)
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
    If (
      $Null -ne $Record -and
      $Null -ne $Record.Value -and
      $Null -ne $Record.Value.InvocationInfo
    ) {
      Write-Debug -Message:(
        'Failed to execute command: {0}' -f [System.String]$Record.Value.InvocationInfo.Line
      )
    }
  } Catch {
    Write-Debug -Message:'Trap diagnostics unavailable for this error record.'
  }

  Break
}

# Under win_powershell the transport provides $Ansible; standalone (a dev
# shell or a Pester spec) it does not, so the script creates a faithful stub.
$StandaloneRun = $Null -eq (
  Get-Variable -Name:'Ansible' -ValueOnly -ErrorAction:'SilentlyContinue'
)
If ($StandaloneRun) {
  $Ansible = [PSCustomObject]@{
    Changed   = $True
    CheckMode = $False
    Failed    = $False
    Result    = $Null
  }
}

$Settings = [System.Collections.Generic.List[System.Object]]::New()
$ChangedSettings = [System.Collections.Generic.List[System.String]]::New()
$DesiredTimeout = [System.TimeSpan]::Zero
$S1Name = 'machineKey.validation'
$S2Name = 'sessionState.timeout'
$S3Name = 'customHeaders'
$S4Name = 'requestFiltering.allowHighBitCharacters'
$S5Name = 'requestLimits.maxAllowedContentLength'

# The transport seeds Changed true. No IIS read has happened yet.
$Ansible.Changed = $False

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

Try {
  $AllowedValidations = [System.String[]]@('HMACSHA256', 'HMACSHA384', 'HMACSHA512')
  If ($MachineKeyValidation -notin $AllowedValidations) {
    Throw (
      'MachineKeyValidation has an invalid value: {0}' -f $MachineKeyValidation
    )
  }

  $TimeoutParsed = [System.TimeSpan]::TryParse(
    $SessionTimeout,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [ref]$DesiredTimeout
  )
  If (-not $TimeoutParsed -or $DesiredTimeout -le [System.TimeSpan]::Zero) {
    Throw ('SessionTimeout has an invalid value: {0}' -f $SessionTimeout)
  }

  If ($MaxAllowedContentLength -lt 1) {
    Throw (
      'MaxAllowedContentLength has an invalid value: {0}' -f $MaxAllowedContentLength
    )
  }

  If ($RemoveResponseHeader -notmatch '^[A-Za-z0-9-]+$') {
    Throw ('RemoveResponseHeader has an invalid value: {0}' -f $RemoveResponseHeader)
  }

  Import-Module -Name:'WebAdministration' -ErrorAction:'Stop'

  $RootPath = 'MACHINE/WEBROOT'
  $AppHostPath = 'MACHINE/WEBROOT/APPHOST'

  # S1: machine-key validation.
  $ValidationBefore = [System.String](
    Get-WebConfigurationProperty `
      -PSPath:$RootPath `
      -Clr:'4.0' `
      -Filter:'system.web/machineKey' `
      -Name:'validation'
  )
  $ValidationChanged = -not [System.String]::Equals(
    $ValidationBefore,
    $MachineKeyValidation,
    [System.StringComparison]::OrdinalIgnoreCase
  )
  $ValidationAfter = $ValidationBefore
  If ($ValidationChanged) {
    $Ansible.Changed = $True
    $ChangedSettings.Add($S1Name)
    If ($PSCmdlet.ShouldProcess($S1Name, 'Set configured value')) {
      Set-WebConfigurationProperty `
        -PSPath:$RootPath `
        -Clr:'4.0' `
        -Filter:'system.web/machineKey' `
        -Name:'validation' `
        -Value:$MachineKeyValidation
      $ValidationAfter = $MachineKeyValidation
    }
  }
  $Settings.Add([PSCustomObject][ordered]@{
      name    = $S1Name
      before  = $ValidationBefore
      after   = $ValidationAfter
      changed = [System.Boolean]$ValidationChanged
    })

  # S2: ASP.NET session timeout.
  $TimeoutAttribute = Get-WebConfigurationProperty `
    -PSPath:$RootPath `
    -Clr:'4.0' `
    -Filter:'system.web/sessionState' `
    -Name:'timeout'
  $TimeoutBeforeValue = [System.TimeSpan]$TimeoutAttribute.Value
  $TimeoutBefore = $TimeoutBeforeValue.ToString(
    'c',
    [System.Globalization.CultureInfo]::InvariantCulture
  )
  $DesiredTimeoutText = $DesiredTimeout.ToString(
    'c',
    [System.Globalization.CultureInfo]::InvariantCulture
  )
  $TimeoutChanged = $TimeoutBeforeValue -ne $DesiredTimeout
  $TimeoutAfter = $TimeoutBefore
  If ($TimeoutChanged) {
    $Ansible.Changed = $True
    $ChangedSettings.Add($S2Name)
    If ($PSCmdlet.ShouldProcess($S2Name, 'Set configured value')) {
      Set-WebConfigurationProperty `
        -PSPath:$RootPath `
        -Clr:'4.0' `
        -Filter:'system.web/sessionState' `
        -Name:'timeout' `
        -Value:$SessionTimeout
      $TimeoutAfter = $DesiredTimeoutText
    }
  }
  $Settings.Add([PSCustomObject][ordered]@{
      name    = $S2Name
      before  = $TimeoutBefore
      after   = $TimeoutAfter
      changed = [System.Boolean]$TimeoutChanged
    })

  # S3: server response header.
  $HeaderConfiguration = Get-WebConfigurationProperty `
    -PSPath:$AppHostPath `
    -Filter:'system.webServer/httpProtocol/customHeaders' `
    -Name:'.'
  $MatchingHeaders = @(
    ForEach ($Header In @($HeaderConfiguration.Collection)) {
      $HeaderName = [System.String]$Header.name
      If ([System.String]::Equals(
          $HeaderName,
          $RemoveResponseHeader,
          [System.StringComparison]::OrdinalIgnoreCase
        )) {
        $HeaderName
      }
    }
  )
  $HeadersBefore = $MatchingHeaders -join ','
  $HeadersChanged = $MatchingHeaders.Count -gt 0
  $HeadersAfter = $HeadersBefore
  If ($HeadersChanged) {
    $Ansible.Changed = $True
    $ChangedSettings.Add($S3Name)
    If ($PSCmdlet.ShouldProcess($S3Name, 'Remove configured header')) {
      ForEach ($HeaderName In $MatchingHeaders) {
        Remove-WebConfigurationProperty `
          -PSPath:$AppHostPath `
          -Filter:'system.webServer/httpProtocol/customHeaders' `
          -Name:'.' `
          -AtElement:@{ name = $HeaderName }
      }
      $HeadersAfter = [System.String]::Empty
    }
  }
  $Settings.Add([PSCustomObject][ordered]@{
      name    = $S3Name
      before  = $HeadersBefore
      after   = $HeadersAfter
      changed = [System.Boolean]$HeadersChanged
    })

  # S4: high-bit characters in request URLs.
  $HighBitAttribute = Get-WebConfigurationProperty `
    -PSPath:$AppHostPath `
    -Filter:'system.webServer/security/requestFiltering' `
    -Name:'allowHighBitCharacters'
  $HighBitBeforeValue = [System.Boolean]$HighBitAttribute.Value
  $HighBitBefore = $HighBitBeforeValue.ToString()
  $HighBitChanged = $HighBitBeforeValue -ne $AllowHighBitCharacters
  $HighBitAfter = $HighBitBefore
  If ($HighBitChanged) {
    $Ansible.Changed = $True
    $ChangedSettings.Add($S4Name)
    If ($PSCmdlet.ShouldProcess($S4Name, 'Set configured value')) {
      Set-WebConfigurationProperty `
        -PSPath:$AppHostPath `
        -Filter:'system.webServer/security/requestFiltering' `
        -Name:'allowHighBitCharacters' `
        -Value:$AllowHighBitCharacters
      $HighBitAfter = $AllowHighBitCharacters.ToString()
    }
  }
  $Settings.Add([PSCustomObject][ordered]@{
      name    = $S4Name
      before  = $HighBitBefore
      after   = $HighBitAfter
      changed = [System.Boolean]$HighBitChanged
    })

  # S5: explicit request-size limit.
  $LimitAttribute = Get-WebConfigurationProperty `
    -PSPath:$AppHostPath `
    -Filter:'system.webServer/security/requestFiltering/requestLimits' `
    -Name:'maxAllowedContentLength'
  $LimitBeforeValue = [System.Int64]$LimitAttribute.Value
  $LimitInherited = [System.Boolean]$LimitAttribute.IsInheritedFromDefaultValue
  $LimitBefore = '{0} {1}' -f $LimitBeforeValue, $(
    If ($LimitInherited) { 'inherited' } Else { 'explicit' }
  )
  $LimitChanged = (
    $LimitBeforeValue -ne [System.Int64]$MaxAllowedContentLength -or
    $LimitInherited
  )
  $LimitAfter = $LimitBefore
  If ($LimitChanged) {
    $Ansible.Changed = $True
    $ChangedSettings.Add($S5Name)
    If ($PSCmdlet.ShouldProcess($S5Name, 'Write explicit configured value')) {
      Add-Type -Path "$env:windir\system32\inetsrv\Microsoft.Web.Administration.dll"
      $ServerManager = New-Object `
        -TypeName:'Microsoft.Web.Administration.ServerManager'
      $Configuration = $ServerManager.GetApplicationHostConfiguration()
      $RequestFiltering = $Configuration.GetSection(
        'system.webServer/security/requestFiltering'
      )
      $RequestLimits = $RequestFiltering.GetChildElement('requestLimits')
      $RequestLimits.SetAttributeValue(
        'maxAllowedContentLength',
        [System.UInt32]$MaxAllowedContentLength
      )
      $ServerManager.CommitChanges()
      $LimitAfter = '{0} explicit' -f $MaxAllowedContentLength
    }
  }
  $Settings.Add([PSCustomObject][ordered]@{
      name    = $S5Name
      before  = $LimitBefore
      after   = $LimitAfter
      changed = [System.Boolean]$LimitChanged
    })
} Catch {
  $Failure = $PSItem
  $Ansible.Result = [PSCustomObject][ordered]@{
    changed  = [System.Boolean]$Ansible.Changed
    settings = [System.Object[]]$Settings.ToArray()
    msg      = [System.String]$Failure.Exception.Message
  }
  $Ansible.Failed = $True
  Throw
}

$Result = [PSCustomObject][ordered]@{
  changed  = [System.Boolean]$Ansible.Changed
  settings = [System.Object[]]$Settings.ToArray()
  msg      = If ($Ansible.Changed) {
    'drift: {0}' -f ($ChangedSettings -join ', ')
  } Else {
    'no drift'
  }
}
#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Ansible.Result = $Result

If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:5
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #

#endregion --- [ Script ] -------------------------------------------------------------------- #
