#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Specification for Set-IisLogDirectory.ps1.

    .DESCRIPTION
        Runs without IIS. The WebAdministration commands and filesystem writes use in-memory
        state, and every attempted write is recorded so change reporting cannot pass by itself.

        A pre-seeded global Ansible object models the win_powershell transport. Its Failed setter
        records whether Result already existed, proving the required failure-publication order.
#>

BeforeAll {
  $script:ScriptPath = Join-Path `
    -Path:$PSScriptRoot `
    -ChildPath:'Set-IisLogDirectory.ps1'
  $script:Desired = 'G:\inetpub\logs\LogFiles'

  Function Reset-FakeIis {
    Param (
      [System.String]$DefaultsDirectory = 'C:\inetpub\logs\LogFiles',
      [System.Boolean]$DefaultsEnabled = $True,
      [System.Object[]]$Sites = @(),
      [System.String[]]$ExistingPaths = @()
    )

    $global:FakeIis = [PSCustomObject]@{
      DefaultsDirectory    = $DefaultsDirectory
      DefaultsEnabled      = $DefaultsEnabled
      ExistingPaths        = [System.Collections.Generic.List[System.String]]::New()
      Imports              = [System.Collections.Generic.List[System.String]]::New()
      Sites                = [System.Object[]]$Sites
      ThrowOnDefaultRead   = $False
      ThrowOnDefaultWrite  = $False
      Writes               = [System.Collections.Generic.List[System.String]]::New()
    }
    ForEach ($ExistingPath In $ExistingPaths) {
      $global:FakeIis.ExistingPaths.Add($ExistingPath)
    }
  }

  Function New-FakeSite {
    Param (
      [System.String]$Name,
      [System.String]$Directory,
      [System.Boolean]$Enabled = $True
    )

    [PSCustomObject]@{
      Name    = $Name
      logFile = [PSCustomObject]@{
        directory = $Directory
        enabled   = $Enabled
      }
    }
  }

  Function Import-Module {
    Param ([System.String]$Name)

    $global:FakeIis.Imports.Add($Name)
  }

  Function Test-Path {
    Param ([System.String]$LiteralPath)

    $global:FakeIis.ExistingPaths -Contains $LiteralPath
  }

  Function New-Item {
    Param (
      [System.String]$ItemType,
      [System.String]$Path,
      [System.Management.Automation.SwitchParameter]$Force
    )

    $global:FakeIis.Writes.Add(('newitem:{0}' -f $Path))
    $global:FakeIis.ExistingPaths.Add($Path)
  }

  Function Get-WebConfigurationProperty {
    Param ([System.String]$Filter, [System.String]$Name)

    If ($global:FakeIis.ThrowOnDefaultRead) {
      Throw 'siteDefaults read failed'
    }
    If ($Name -eq 'directory') {
      [PSCustomObject]@{ Value = $global:FakeIis.DefaultsDirectory }
    } Else {
      [PSCustomObject]@{ Value = $global:FakeIis.DefaultsEnabled }
    }
  }

  Function Set-WebConfigurationProperty {
    Param ([System.String]$Filter, [System.String]$Name, $Value)

    $global:FakeIis.Writes.Add(('defaults:{0}={1}' -f $Name, $Value))
    If ($global:FakeIis.ThrowOnDefaultWrite) {
      Throw 'siteDefaults write failed'
    }
    If ($Name -eq 'directory') {
      $global:FakeIis.DefaultsDirectory = [System.String]$Value
    } Else {
      $global:FakeIis.DefaultsEnabled = [System.Boolean]$Value
    }
  }

  Function Get-Website {
    $global:FakeIis.Sites
  }

  Function Set-ItemProperty {
    Param ([System.String]$LiteralPath, [System.String]$Name, $Value)

    $global:FakeIis.Writes.Add(('site:{0}|{1}={2}' -f $LiteralPath, $Name, $Value))
  }

  Function Invoke-Script {
    Param (
      [System.String]$LogDirectory = $script:Desired,
      [System.Management.Automation.SwitchParameter]$WhatIf,
      [System.Boolean]$CheckMode = $False
    )

    $global:PublicationOrder = [System.Collections.Generic.List[System.String]]::New()
    $global:Ansible = [PSCustomObject]@{
      Changed   = $True
      CheckMode = $CheckMode
      FailedSet = $False
      Result    = $Null
    }
    $global:Ansible | Add-Member -MemberType:'ScriptProperty' -Name:'Failed' -Value:{
      $this.FailedSet
    } -SecondValue:{
      Param ($Value)
      If ($Value) {
        If ($Null -eq $this.Result) {
          $global:PublicationOrder.Add('failed-before-result')
        } Else {
          $global:PublicationOrder.Add('result-before-failed')
        }
      }
      $this.FailedSet = [System.Boolean]$Value
    }

    If ($WhatIf) {
      & $script:ScriptPath -LogDirectory:$LogDirectory -WhatIf
    } Else {
      & $script:ScriptPath -LogDirectory:$LogDirectory
    }
    $global:Ansible
  }
}

Describe 'Set-IisLogDirectory' {

  It 'P1 creates a fresh directory and rewrites drifting siteDefaults' {
    Reset-FakeIis `
      -DefaultsDirectory:'%SystemDrive%\inetpub\logs\LogFiles' `
      -Sites:@(
        New-FakeSite `
          -Name:'WSUS Administration' `
          -Directory:$script:Desired
      )

    $Result = Invoke-Script

    $Result.Result.created | Should -BeTrue
    $Result.Result.site_defaults_changed | Should -BeTrue
    @($Result.Result.sites).Count | Should -Be 0
    $Result.Changed | Should -BeTrue
    @($global:FakeIis.Writes) | Should -Be @(
      'newitem:G:\inetpub\logs\LogFiles'
      'defaults:directory=G:\inetpub\logs\LogFiles'
    )
  }

  It 'P2 treats case and a trailing separator as converged' {
    Reset-FakeIis `
      -DefaultsDirectory:'g:\INETPUB\logs\LogFiles\' `
      -ExistingPaths:@($script:Desired) `
      -Sites:@(
        New-FakeSite `
          -Name:'WSUS Administration' `
          -Directory:'G:\inetpub\LOGS\logfiles\'
      )

    $Result = Invoke-Script

    $Result.Changed | Should -BeFalse
    $Result.Result.changed | Should -BeFalse
    $global:FakeIis.Writes.Count | Should -Be 0
  }

  It 'P3 rewrites only a site with a directory override' {
    Reset-FakeIis `
      -DefaultsDirectory:$script:Desired `
      -ExistingPaths:@($script:Desired) `
      -Sites:@(
        New-FakeSite `
          -Name:'WSUS Administration' `
          -Directory:'C:\inetpub\logs\LogFiles'
      )

    $Result = Invoke-Script

    @($Result.Result.sites) | Should -Be @('WSUS Administration')
    @($global:FakeIis.Writes) | Should -Be @(
      'site:IIS:\Sites\WSUS Administration|logFile.directory=G:\inetpub\logs\LogFiles'
    )
  }

  It 'P4 treats a token in siteDefaults as drift' {
    Reset-FakeIis `
      -DefaultsDirectory:'%IISLOG%\inetpub\logs\LogFiles' `
      -ExistingPaths:@($script:Desired)

    $Result = Invoke-Script

    $Result.Changed | Should -BeTrue
    $Result.Result.site_defaults_changed | Should -BeTrue
    @($global:FakeIis.Writes) | Should -Be @(
      'defaults:directory=G:\inetpub\logs\LogFiles'
    )
  }

  It 'P5 refuses a percent-token input before imports or writes' {
    $BadValue = '%SystemDrive%\inetpub\logs'
    Reset-FakeIis

    { Invoke-Script -LogDirectory:$BadValue } | Should -Throw -ExpectedMessage "*$BadValue*"

    $global:Ansible.Result.msg | Should -BeLike "*$BadValue*"
    $global:Ansible.Failed | Should -BeTrue
    $global:Ansible.Changed | Should -BeFalse
    $global:FakeIis.Writes.Count | Should -Be 0
    $global:FakeIis.Imports.Count | Should -Be 0
  }

  It 'P6 refuses a relative input before imports or writes' {
    $BadValue = 'inetpub\logs'
    Reset-FakeIis

    { Invoke-Script -LogDirectory:$BadValue } | Should -Throw -ExpectedMessage "*$BadValue*"

    $global:Ansible.Result.msg | Should -BeLike "*$BadValue*"
    $global:Ansible.Failed | Should -BeTrue
    $global:Ansible.Changed | Should -BeFalse
    $global:FakeIis.Writes.Count | Should -Be 0
    $global:FakeIis.Imports.Count | Should -Be 0
  }

  It 'P7 reports drift under WhatIf and check mode without writing' {
    Reset-FakeIis `
      -DefaultsDirectory:'C:\inetpub\logs\LogFiles' `
      -ExistingPaths:@($script:Desired)

    $Result = Invoke-Script -WhatIf -CheckMode:$True

    $Result.CheckMode | Should -BeTrue
    $Result.Changed | Should -BeTrue
    $Result.Result.changed | Should -BeTrue
    $global:FakeIis.Writes.Count | Should -Be 0
  }

  It 'P8 enables logging at siteDefaults and on a disabled site' {
    Reset-FakeIis `
      -DefaultsDirectory:$script:Desired `
      -DefaultsEnabled:$False `
      -ExistingPaths:@($script:Desired) `
      -Sites:@(
        New-FakeSite `
          -Name:'WSUS Administration' `
          -Directory:$script:Desired `
          -Enabled:$False
      )

    $Result = Invoke-Script

    $Result.Result.site_defaults_changed | Should -BeTrue
    @($Result.Result.sites) | Should -Be @('WSUS Administration')
    @($global:FakeIis.Writes) | Should -Be @(
      'defaults:enabled=True'
      'site:IIS:\Sites\WSUS Administration|logFile.enabled=True'
    )
  }

  It 'P9 publishes Result before Failed when a read throws' {
    Reset-FakeIis -ExistingPaths:@($script:Desired)
    $global:FakeIis.ThrowOnDefaultRead = $True

    { Invoke-Script } | Should -Throw -ExpectedMessage '*siteDefaults read failed*'

    $global:PublicationOrder | Should -Be @('result-before-failed')
    $global:Ansible.Failed | Should -BeTrue
    $global:Ansible.Result.msg | Should -Be 'siteDefaults read failed'
    $global:FakeIis.Writes.Count | Should -Be 0
  }

  It 'P10 publishes the full changed result after create then write failure' {
    Reset-FakeIis -DefaultsDirectory:'C:\inetpub\logs\LogFiles'
    $global:FakeIis.ThrowOnDefaultWrite = $True

    { Invoke-Script } | Should -Throw -ExpectedMessage '*siteDefaults write failed*'

    $global:PublicationOrder | Should -Be @('result-before-failed')
    $global:Ansible.Failed | Should -BeTrue
    $global:Ansible.Changed | Should -BeTrue
    $global:Ansible.Result.changed | Should -BeTrue
    $global:Ansible.Result.directory | Should -Be $script:Desired
    $global:Ansible.Result.created | Should -BeTrue
    $global:Ansible.Result.site_defaults_changed | Should -BeTrue
    @($global:Ansible.Result.sites).Count | Should -Be 0
    $global:Ansible.Result.msg | Should -Be 'siteDefaults write failed'
    ForEach ($Name In @(
        'changed', 'directory', 'created', 'site_defaults_changed', 'sites', 'msg'
      )) {
      $global:Ansible.Result.PSObject.Properties.Name | Should -Contain $Name
    }
    @($global:FakeIis.Writes) | Should -Be @(
      'newitem:G:\inetpub\logs\LogFiles'
      'defaults:directory=G:\inetpub\logs\LogFiles'
    )
  }
}
