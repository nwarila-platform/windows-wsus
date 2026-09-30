#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Points IIS request logging at one literal directory, for siteDefaults and for every site
        that exists.

    .DESCRIPTION
        Two levels, because either one alone leaves logs on the system volume. siteDefaults is
        what a site created LATER inherits; a site created EARLIER carries its own
        logFile.directory that overrides it. WSUS post-installation creates its site before this
        runs, so setting only siteDefaults would move nothing that exists, and setting only the
        sites would leave the next site to land back on C:.

        A configured path carrying a %VAR% token is refused rather than expanded. The reason is
        auditability, not tidiness: IIS stores the token and resolves it per-process, so two
        readers can disagree about where the logs are, and a STIG check reading the configured
        value cannot tell which volume it names. The declared value must therefore be literal and
        drive-qualified, and a token found in the CURRENT configuration counts as drift to be
        corrected rather than as a match.

        Comparison is case-insensitive and ignores a trailing separator, because IIS accepts and
        returns either form. Without that this reports a change on every run and the converge
        never settles.

        Change reporting is per-write, not per-run: the directory create, the two siteDefaults
        properties and each site's two properties are each compared before being set, so a
        converged host reports changed false and the second converge is a genuine no-op.

    .PARAMETER LogDirectory
        Literal, drive-qualified directory the logs are written to, for example
        'G:\inetpub\logs\LogFiles'. A %VAR% token is refused.

    .EXAMPLE
        .\Set-IisLogDirectory.ps1 -LogDirectory 'G:\inetpub\logs\LogFiles'

    .OUTPUTS
        One object carrying changed, directory, created, site_defaults_changed and sites -- the
        last a list of the sites whose logging this invocation rewrote.
#>

[CmdletBinding(SupportsShouldProcess)]
[OutputType([System.Void])]
Param (
  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String]$LogDirectory
)

#region ------ [ Initialization ] ------------------------------------------------------------ #
Set-StrictMode -Version:'Latest'
$ErrorActionPreference = 'Stop'

# Under win_powershell the transport provides $Ansible; standalone (a dev shell or a Pester spec)
# it does not, so the script creates a faithful stub.
$StandaloneRun = $Null -eq (Get-Variable -Name:'Ansible' -ValueOnly -ErrorAction:'SilentlyContinue')
If ($StandaloneRun) {
  $Ansible = [PSCustomObject]@{
    Changed   = $True
    CheckMode = $False
    Failed    = $False
    Result    = $Null
  }
}

# The transport seeds Changed true. Nothing below may inherit it: a throw must not report a change
# that was never made.
$Ansible.Changed = $False
#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Helpers ] ------------------------------------------------------------------- #
# One normal form for every comparison. IIS returns 'G:\x', 'G:\x\' and 'g:/x' interchangeably,
# so without this the converged host looks like drift on every run.
Function ConvertTo-NormalPath {
  [CmdletBinding()]
  [OutputType([System.String])]
  Param ([AllowNull()][AllowEmptyString()][System.String]$Path)

  If ([System.String]::IsNullOrWhiteSpace($Path)) { Return '' }
  Return $Path.Trim().Replace('/', [System.Char]92).TrimEnd([System.Char]92)
}

# A token is not a match even when it would expand to the right place: the configured value is
# what an auditor reads, and it must name the volume outright.
Function Test-ConfiguredPath {
  [CmdletBinding()]
  [OutputType([System.Boolean])]
  Param (
    [AllowNull()][AllowEmptyString()][System.String]$Current,
    [Parameter(Mandatory = $True)][System.String]$Desired
  )

  $Normal = ConvertTo-NormalPath -Path:$Current
  If ($Normal -Match '%[^%]+%') { Return $False }
  Return [System.String]::Equals($Normal, $Desired, [System.StringComparison]::OrdinalIgnoreCase)
}
#endregion --- [ Helpers ] ------------------------------------------------------------------- #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Import-Module -Name:'WebAdministration' -ErrorAction:'Stop'

$Desired = ConvertTo-NormalPath -Path:$LogDirectory
If ($Desired -Match '%[^%]+%' -Or $Desired -NotMatch '^[A-Za-z]:') {
  Throw ('LogDirectory must be a literal drive-qualified path with no %VAR% token: ' + $LogDirectory)
}

$Created = $False
$SiteDefaultsChanged = $False
$RewrittenSites = [System.Collections.Generic.List[System.String]]::New()

If (-Not (Test-Path -LiteralPath:$Desired)) {
  If ($PSCmdlet.ShouldProcess($Desired, 'Create the IIS log directory')) {
    $Null = New-Item -ItemType:'Directory' -Path:$Desired -Force
  }
  $Created = $True
  $Ansible.Changed = $True
}

$DefaultsFilter = 'system.applicationHost/sites/siteDefaults/logFile'

$CurrentDefault = (Get-WebConfigurationProperty -Filter:$DefaultsFilter -Name:'directory').Value
If (-Not (Test-ConfiguredPath -Current:$CurrentDefault -Desired:$Desired)) {
  If ($PSCmdlet.ShouldProcess('siteDefaults', 'Set logFile.directory')) {
    Set-WebConfigurationProperty -Filter:$DefaultsFilter -Name:'directory' -Value:$Desired
  }
  $SiteDefaultsChanged = $True
  $Ansible.Changed = $True
}

$CurrentEnabled = (Get-WebConfigurationProperty -Filter:$DefaultsFilter -Name:'enabled').Value
If (-Not [System.Convert]::ToBoolean($CurrentEnabled)) {
  If ($PSCmdlet.ShouldProcess('siteDefaults', 'Enable logFile')) {
    Set-WebConfigurationProperty -Filter:$DefaultsFilter -Name:'enabled' -Value:$True
  }
  $SiteDefaultsChanged = $True
  $Ansible.Changed = $True
}

# @() so a single site does not arrive as a bare object the foreach would still iterate, but
# whose .Count a later reader would find missing under StrictMode.
ForEach ($Site In @(Get-Website)) {
  $SitePath = 'IIS:\Sites' + [System.Char]92 + $Site.Name
  $SiteTouched = $False

  If (-Not (Test-ConfiguredPath -Current:$Site.logFile.directory -Desired:$Desired)) {
    If ($PSCmdlet.ShouldProcess($Site.Name, 'Set logFile.directory')) {
      Set-ItemProperty -LiteralPath:$SitePath -Name:'logFile.directory' -Value:$Desired
    }
    $SiteTouched = $True
  }

  If (-Not [System.Convert]::ToBoolean($Site.logFile.enabled)) {
    If ($PSCmdlet.ShouldProcess($Site.Name, 'Enable logFile')) {
      Set-ItemProperty -LiteralPath:$SitePath -Name:'logFile.enabled' -Value:$True
    }
    $SiteTouched = $True
  }

  If ($SiteTouched) {
    $RewrittenSites.Add($Site.Name)
    $Ansible.Changed = $True
  }
}

$Ansible.Result = [PSCustomObject]@{
  changed               = $Ansible.Changed
  directory             = $Desired
  created               = $Created
  site_defaults_changed = $SiteDefaultsChanged
  sites                 = $RewrittenSites.ToArray()
}

If ($StandaloneRun) { $Ansible.Result }
#endregion --- [ Main ] ---------------------------------------------------------------------- #
