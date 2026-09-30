#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Points IIS request logging at one literal directory.

    .DESCRIPTION
        Writes both siteDefaults and every existing site. Sites created later inherit
        siteDefaults, while sites that already exist can carry their own overriding logging
        properties. Both levels must agree to keep request logs off the system volume.

        A configured path carrying a %VAR% token is drift even when expansion would produce the
        declared directory. Comparison is case-insensitive and ignores trailing separators.

        Every write is guarded by ShouldProcess. Check mode therefore reports required changes
        without creating the directory or changing IIS.

    .PARAMETER DebugLevel
        Three digits: ErrorActionPreference, Set-PSDebug, Set-StrictMode.

    .PARAMETER LogLevel
        Six digits, one per stream: Verbose, Debug, Information, Warning, Error, Fatal.

    .PARAMETER LogDirectory
        Literal, drive-qualified directory for IIS request logs, for example
        'G:\inetpub\logs\LogFiles'. Percent tokens are refused.

    .EXAMPLE
        Set-IisLogDirectory.ps1 -LogDirectory 'G:\inetpub\logs\LogFiles'

    .OUTPUTS
        One object carrying changed, directory, created, site_defaults_changed, sites and msg.
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
  $LogDirectory
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

# Failure publication needs these fields even when validation refuses the input before any read.
$Desired = [System.String]::Empty
$Created = $False
$SiteDefaultsChanged = $False
$RewrittenSites = [System.Collections.Generic.List[System.String]]::New()

# The transport seeds Changed true. No IIS or filesystem read has happened yet.
$Ansible.Changed = $False

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

Try {
  $Desired = $LogDirectory.Trim().Replace('/', [System.Char]92).TrimEnd([System.Char]92)

  # Refuse an ambiguous or relative destination before loading WebAdministration or reading IIS.
  If ($Desired -NotMatch '^[A-Za-z]:\\' -or $Desired.Contains('%')) {
    Throw (
      'LogDirectory must be a literal drive-qualified path with no % token: {0}' -f
      $LogDirectory
    )
  }

  Import-Module -Name:'WebAdministration' -ErrorAction:'Stop'

  If (-not (Test-Path -LiteralPath:$Desired)) {
    $Created = $True
    $Ansible.Changed = $True
    If ($PSCmdlet.ShouldProcess($Desired, 'Create the IIS log directory')) {
      $Null = New-Item -ItemType:'Directory' -Path:$Desired -Force
    }
  }

  $DefaultsFilter = 'system.applicationHost/sites/siteDefaults/logFile'
  $CurrentDefault = [System.String](
    Get-WebConfigurationProperty -Filter:$DefaultsFilter -Name:'directory'
  ).Value
  $NormalDefault = $CurrentDefault.Trim().Replace(
    '/', [System.Char]92
  ).TrimEnd([System.Char]92)
  $DefaultMatches = (
    $NormalDefault -NotMatch '%[^%]+%' -and
    [System.String]::Equals(
      $NormalDefault,
      $Desired,
      [System.StringComparison]::OrdinalIgnoreCase
    )
  )

  If (-not $DefaultMatches) {
    $SiteDefaultsChanged = $True
    $Ansible.Changed = $True
    If ($PSCmdlet.ShouldProcess('siteDefaults', 'Set logFile.directory')) {
      Set-WebConfigurationProperty `
        -Filter:$DefaultsFilter `
        -Name:'directory' `
        -Value:$Desired
    }
  }

  $CurrentEnabled = (
    Get-WebConfigurationProperty -Filter:$DefaultsFilter -Name:'enabled'
  ).Value
  If (-not [System.Convert]::ToBoolean($CurrentEnabled)) {
    $SiteDefaultsChanged = $True
    $Ansible.Changed = $True
    If ($PSCmdlet.ShouldProcess('siteDefaults', 'Enable logFile')) {
      Set-WebConfigurationProperty `
        -Filter:$DefaultsFilter `
        -Name:'enabled' `
        -Value:$True
    }
  }

  ForEach ($Site In @(Get-Website)) {
    $SitePath = 'IIS:\Sites' + [System.Char]92 + $Site.Name
    $SiteTouched = $False
    $CurrentSite = [System.String]$Site.logFile.directory
    $NormalSite = $CurrentSite.Trim().Replace(
      '/', [System.Char]92
    ).TrimEnd([System.Char]92)
    $SiteMatches = (
      $NormalSite -NotMatch '%[^%]+%' -and
      [System.String]::Equals(
        $NormalSite,
        $Desired,
        [System.StringComparison]::OrdinalIgnoreCase
      )
    )

    If (-not $SiteMatches) {
      $SiteTouched = $True
      $RewrittenSites.Add([System.String]$Site.Name)
      $Ansible.Changed = $True
      If ($PSCmdlet.ShouldProcess($Site.Name, 'Set logFile.directory')) {
        Set-ItemProperty `
          -LiteralPath:$SitePath `
          -Name:'logFile.directory' `
          -Value:$Desired
      }
    }

    If (-not [System.Convert]::ToBoolean($Site.logFile.enabled)) {
      If (-not $SiteTouched) {
        $RewrittenSites.Add([System.String]$Site.Name)
      }
      $SiteTouched = $True
      $Ansible.Changed = $True
      If ($PSCmdlet.ShouldProcess($Site.Name, 'Enable logFile')) {
        Set-ItemProperty `
          -LiteralPath:$SitePath `
          -Name:'logFile.enabled' `
          -Value:$True
      }
    }
  }
} Catch {
  $Failure = $PSItem
  $Ansible.Result = [PSCustomObject]@{
    changed               = [System.Boolean]$Ansible.Changed
    directory             = [System.String]$Desired
    created               = [System.Boolean]$Created
    site_defaults_changed = [System.Boolean]$SiteDefaultsChanged
    sites                 = [System.String[]]$RewrittenSites.ToArray()
    msg                   = [System.String]$Failure.Exception.Message
  }
  $Ansible.Failed = $True
  Throw
}

$Result = [PSCustomObject]@{
  changed               = [System.Boolean]$Ansible.Changed
  directory             = [System.String]$Desired
  created               = [System.Boolean]$Created
  site_defaults_changed = [System.Boolean]$SiteDefaultsChanged
  sites                 = [System.String[]]$RewrittenSites.ToArray()
  msg                   = If ($Ansible.Changed) {
    'IIS request logging points at {0}' -f $Desired
  } Else {
    'IIS request logging already points at {0}' -f $Desired
  }
}
#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Ansible.Result = $Result

If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:4
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #

#endregion --- [ Script ] -------------------------------------------------------------------- #
