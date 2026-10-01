#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Specification for Set-IisServerHardening.ps1.

    .DESCRIPTION
        Runs without IIS. WebAdministration and ServerManager use in-memory state, and every
        attempted write is recorded so change reporting cannot pass by itself.

        A pre-seeded global Ansible object models the win_powershell transport. Its Failed setter
        records whether Result already existed, proving the required failure-publication order.
#>

BeforeAll {
  $script:ScriptPath = Join-Path `
    -Path:$PSScriptRoot `
    -ChildPath:'Set-IisServerHardening.ps1'
  $script:DesiredValidation = 'HMACSHA256'
  $script:DesiredTimeout = '00:15:00'
  $script:DesiredHighBit = $False
  $script:DesiredLimit = [System.UInt32]30000000
  $script:DesiredHeader = 'X-Powered-By'
  $env:windir = 'C:\Windows'

  Function Reset-FakeIis {
    Param (
      [System.String]$Validation = $script:DesiredValidation,
      [System.TimeSpan]$Timeout = [System.TimeSpan]'00:15:00',
      [System.String[]]$Headers = @(),
      [System.Boolean]$AllowHighBitCharacters = $False,
      [System.Int64]$Limit = 30000000,
      [System.Boolean]$LimitInherited = $False
    )

    $global:FakeIis = [PSCustomObject]@{
      AllowHighBitCharacters = $AllowHighBitCharacters
      Headers                = [System.String[]]$Headers
      Imports                = [System.Collections.Generic.List[System.String]]::New()
      Limit                  = $Limit
      LimitInherited         = $LimitInherited
      Mechanisms             = [System.Collections.Generic.List[System.String]]::New()
      PendingLimit           = [System.UInt32]0
      Reads                  = [System.Collections.Generic.List[System.String]]::New()
      ServerManager          = $Null
      ThrowOnRead            = [System.String]::Empty
      ThrowOnWrite           = [System.String]::Empty
      Timeout                = $Timeout
      Validation             = $Validation
      Writes                 = [System.Collections.Generic.List[System.String]]::New()
    }

    $RequestLimits = [PSCustomObject]@{}
    $RequestLimits | Add-Member -MemberType:'ScriptMethod' -Name:'SetAttributeValue' -Value:{
      Param ([System.String]$Name, $Value)

      $Key = 'S5'
      $global:FakeIis.Writes.Add(
        ('S5:requestLimits.maxAllowedContentLength={0}' -f $Value)
      )
      If ($global:FakeIis.ThrowOnWrite -eq $Key) {
        Throw 'S5 write failed'
      }
      $global:FakeIis.PendingLimit = [System.UInt32]$Value
    }

    $RequestFiltering = [PSCustomObject]@{}
    $RequestFiltering | Add-Member `
      -MemberType:'ScriptMethod' `
      -Name:'GetChildElement' `
      -Value:{
        Param ([System.String]$Name)

        $global:FakeIis.RequestLimits
      }

    $Configuration = [PSCustomObject]@{}
    $Configuration | Add-Member -MemberType:'ScriptMethod' -Name:'GetSection' -Value:{
      Param ([System.String]$Name)

      $global:FakeIis.RequestFiltering
    }

    $ServerManager = [PSCustomObject]@{}
    $ServerManager | Add-Member `
      -MemberType:'ScriptMethod' `
      -Name:'GetApplicationHostConfiguration' `
      -Value:{
        $global:FakeIis.Configuration
      }
    $ServerManager | Add-Member -MemberType:'ScriptMethod' -Name:'CommitChanges' -Value:{
      $global:FakeIis.Mechanisms.Add('CommitChanges')
      $global:FakeIis.Limit = [System.Int64]$global:FakeIis.PendingLimit
      $global:FakeIis.LimitInherited = $False
    }

    $global:FakeIis | Add-Member `
      -MemberType:'NoteProperty' `
      -Name:'Configuration' `
      -Value:$Configuration
    $global:FakeIis | Add-Member `
      -MemberType:'NoteProperty' `
      -Name:'RequestFiltering' `
      -Value:$RequestFiltering
    $global:FakeIis | Add-Member `
      -MemberType:'NoteProperty' `
      -Name:'RequestLimits' `
      -Value:$RequestLimits
    $global:FakeIis.ServerManager = $ServerManager
  }

  Function Import-Module {
    Param ([System.String]$Name, $ErrorAction)

    $global:FakeIis.Imports.Add($Name)
  }

  Function Get-WebConfigurationProperty {
    Param (
      [System.String]$PSPath,
      [System.String]$Clr,
      [System.String]$Filter,
      [System.String]$Name
    )

    $Key = Switch ($Filter) {
      'system.web/machineKey' { 'S1' }
      'system.web/sessionState' { 'S2' }
      'system.webServer/httpProtocol/customHeaders' { 'S3' }
      'system.webServer/security/requestFiltering' { 'S4' }
      'system.webServer/security/requestFiltering/requestLimits' { 'S5' }
    }
    $global:FakeIis.Reads.Add($Key)
    If ($global:FakeIis.ThrowOnRead -eq $Key) {
      Throw ("$Key read failed")
    }

    Switch ($Key) {
      'S1' {
        $global:FakeIis.Validation
      }
      'S2' {
        [PSCustomObject]@{ Value = $global:FakeIis.Timeout }
      }
      'S3' {
        $Elements = @(
          ForEach ($Header In $global:FakeIis.Headers) {
            [PSCustomObject]@{ name = $Header }
          }
        )
        [PSCustomObject]@{ Collection = [System.Object[]]$Elements }
      }
      'S4' {
        [PSCustomObject]@{ Value = $global:FakeIis.AllowHighBitCharacters }
      }
      'S5' {
        [PSCustomObject]@{
          IsInheritedFromDefaultValue = $global:FakeIis.LimitInherited
          Value                       = [System.Int64]$global:FakeIis.Limit
        }
      }
    }
  }

  Function Set-WebConfigurationProperty {
    Param (
      [System.String]$PSPath,
      [System.String]$Clr,
      [System.String]$Filter,
      [System.String]$Name,
      $Value
    )

    If ($Filter -eq 'system.web/machineKey') {
      $Key = 'S1'
      $Setting = 'machineKey.validation'
    } ElseIf ($Filter -eq 'system.web/sessionState') {
      $Key = 'S2'
      $Setting = 'sessionState.timeout'
    } Else {
      $Key = 'S4'
      $Setting = 'requestFiltering.allowHighBitCharacters'
    }
    $global:FakeIis.Writes.Add(('{0}:{1}={2}' -f $Key, $Setting, $Value))
    If ($global:FakeIis.ThrowOnWrite -eq $Key) {
      Throw ("$Key write failed")
    }

    Switch ($Key) {
      'S1' {
        $global:FakeIis.Validation = [System.String]$Value
      }
      'S2' {
        $global:FakeIis.Timeout = [System.TimeSpan]::Parse(
          [System.String]$Value,
          [System.Globalization.CultureInfo]::InvariantCulture
        )
      }
      'S4' {
        $global:FakeIis.AllowHighBitCharacters = [System.Boolean]$Value
      }
    }
  }

  Function Remove-WebConfigurationProperty {
    Param (
      [System.String]$PSPath,
      [System.String]$Filter,
      [System.String]$Name,
      [System.Collections.Hashtable]$AtElement
    )

    $HeaderName = [System.String]$AtElement.name
    $global:FakeIis.Writes.Add(('S3:customHeaders={0}' -f $HeaderName))
    If ($global:FakeIis.ThrowOnWrite -eq 'S3') {
      Throw 'S3 write failed'
    }
    $Remaining = [System.Collections.Generic.List[System.String]]::New()
    ForEach ($Header In $global:FakeIis.Headers) {
      If (-not [System.String]::Equals(
          $Header,
          $HeaderName,
          [System.StringComparison]::OrdinalIgnoreCase
        )) {
        $Remaining.Add($Header)
      }
    }
    $global:FakeIis.Headers = [System.String[]]$Remaining.ToArray()
  }

  Function Add-Type {
    Param ([System.String]$Path)

    $global:FakeIis.Mechanisms.Add(('Add-Type:{0}' -f $Path))
  }

  Function New-Object {
    Param ([System.String]$TypeName)

    $global:FakeIis.Mechanisms.Add(('New-Object:{0}' -f $TypeName))
    $global:FakeIis.ServerManager
  }

  Function Invoke-Script {
    Param (
      [System.String]$MachineKeyValidation = $script:DesiredValidation,
      [System.String]$SessionTimeout = $script:DesiredTimeout,
      [System.Boolean]$AllowHighBitCharacters = $script:DesiredHighBit,
      [System.UInt32]$MaxAllowedContentLength = $script:DesiredLimit,
      [System.String]$RemoveResponseHeader = $script:DesiredHeader,
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

    $Parameters = @{
      AllowHighBitCharacters   = $AllowHighBitCharacters
      MachineKeyValidation     = $MachineKeyValidation
      MaxAllowedContentLength  = $MaxAllowedContentLength
      RemoveResponseHeader     = $RemoveResponseHeader
      SessionTimeout           = $SessionTimeout
    }
    If ($WhatIf) {
      & $script:ScriptPath @Parameters -WhatIf
    } Else {
      & $script:ScriptPath @Parameters
    }
    $global:Ansible
  }

  Function Assert-ResultKeys {
    Param ($Result)

    @($Result.PSObject.Properties.Name) | Should -Be @('changed', 'settings', 'msg')
  }

  Function Assert-Setting {
    Param (
      $Entry,
      [System.String]$Name,
      [System.String]$Before,
      [System.String]$After,
      [System.Boolean]$Changed
    )

    @($Entry.PSObject.Properties.Name) | Should -Be @(
      'name', 'before', 'after', 'changed'
    )
    $Entry.name | Should -Be $Name
    $Entry.before | Should -Be $Before
    $Entry.after | Should -Be $After
    $Entry.changed | Should -Be $Changed
  }
}

Describe 'Set-IisServerHardening' {

  It 'P1 writes all five settings in order and publishes their exact results' {
    Reset-FakeIis `
      -Validation:'SHA1' `
      -Timeout:([System.TimeSpan]'00:20:00') `
      -Headers:@('X-Powered-By') `
      -AllowHighBitCharacters:$True `
      -LimitInherited:$True

    $Result = Invoke-Script

    $Result.Changed | Should -BeTrue
    Assert-ResultKeys -Result:$Result.Result
    $Result.Result.changed | Should -BeTrue
    @($Result.Result.settings).Count | Should -Be 5
    Assert-Setting $Result.Result.settings[0] `
      'machineKey.validation' 'SHA1' 'HMACSHA256' $True
    Assert-Setting $Result.Result.settings[1] `
      'sessionState.timeout' '00:20:00' '00:15:00' $True
    Assert-Setting $Result.Result.settings[2] `
      'customHeaders' 'X-Powered-By' '' $True
    Assert-Setting $Result.Result.settings[3] `
      'requestFiltering.allowHighBitCharacters' 'True' 'False' $True
    Assert-Setting $Result.Result.settings[4] `
      'requestLimits.maxAllowedContentLength' `
      '30000000 inherited' '30000000 explicit' $True
    $ExpectedNames = @(
      'machineKey.validation'
      'sessionState.timeout'
      'customHeaders'
      'requestFiltering.allowHighBitCharacters'
      'requestLimits.maxAllowedContentLength'
    )
    $Result.Result.msg | Should -Be ('drift: {0}' -f ($ExpectedNames -join ', '))
    @($global:FakeIis.Writes) | Should -Be @(
      'S1:machineKey.validation=HMACSHA256'
      'S2:sessionState.timeout=00:15:00'
      'S3:customHeaders=X-Powered-By'
      'S4:requestFiltering.allowHighBitCharacters=False'
      'S5:requestLimits.maxAllowedContentLength=30000000'
    )
  }

  It 'P2 reports no drift for the five converged explicit settings' {
    Reset-FakeIis

    $Result = Invoke-Script

    $Result.Changed | Should -BeFalse
    Assert-ResultKeys -Result:$Result.Result
    $Result.Result.changed | Should -BeFalse
    @($Result.Result.settings).Count | Should -Be 5
    Assert-Setting $Result.Result.settings[0] `
      'machineKey.validation' 'HMACSHA256' 'HMACSHA256' $False
    Assert-Setting $Result.Result.settings[1] `
      'sessionState.timeout' '00:15:00' '00:15:00' $False
    Assert-Setting $Result.Result.settings[2] 'customHeaders' '' '' $False
    Assert-Setting $Result.Result.settings[3] `
      'requestFiltering.allowHighBitCharacters' 'False' 'False' $False
    Assert-Setting $Result.Result.settings[4] `
      'requestLimits.maxAllowedContentLength' `
      '30000000 explicit' '30000000 explicit' $False
    $Result.Result.msg | Should -Be 'no drift'
    $global:FakeIis.Writes.Count | Should -Be 0
  }

  It 'P3 writes only machine-key validation when it is the sole drift' {
    Reset-FakeIis -Validation:'SHA1'

    $Result = Invoke-Script

    $Result.Changed | Should -BeTrue
    Assert-Setting $Result.Result.settings[0] `
      'machineKey.validation' 'SHA1' 'HMACSHA256' $True
    $Result.Result.msg | Should -Be 'drift: machineKey.validation'
    @($global:FakeIis.Writes) | Should -Be @(
      'S1:machineKey.validation=HMACSHA256'
    )
  }

  It 'P4 writes only a drifting timeout and compares an equal TimeSpan as converged' {
    Reset-FakeIis -Timeout:([System.TimeSpan]'00:30:00')

    $Result = Invoke-Script

    $Result.Changed | Should -BeTrue
    Assert-Setting $Result.Result.settings[1] `
      'sessionState.timeout' '00:30:00' '00:15:00' $True
    @($global:FakeIis.Writes) | Should -Be @(
      'S2:sessionState.timeout=00:15:00'
    )

    Reset-FakeIis -Timeout:([System.TimeSpan]'00:15:00')
    $EqualResult = Invoke-Script

    $EqualResult.Changed | Should -BeFalse
    Assert-Setting $EqualResult.Result.settings[1] `
      'sessionState.timeout' '00:15:00' '00:15:00' $False
    $global:FakeIis.Writes.Count | Should -Be 0
  }

  It 'P5 removes a response header matched case-insensitively' {
    Reset-FakeIis -Headers:@('x-powered-by')

    $Result = Invoke-Script

    $Result.Changed | Should -BeTrue
    Assert-Setting $Result.Result.settings[2] `
      'customHeaders' 'x-powered-by' '' $True
    @($global:FakeIis.Writes) | Should -Be @(
      'S3:customHeaders=x-powered-by'
    )
  }

  It 'P6 writes only high-bit filtering when it is the sole drift' {
    Reset-FakeIis -AllowHighBitCharacters:$True

    $Result = Invoke-Script

    $Result.Changed | Should -BeTrue
    Assert-Setting $Result.Result.settings[3] `
      'requestFiltering.allowHighBitCharacters' 'True' 'False' $True
    @($global:FakeIis.Writes) | Should -Be @(
      'S4:requestFiltering.allowHighBitCharacters=False'
    )
  }

  It 'P7 writes a different explicit limit through ServerManager' {
    Reset-FakeIis -Limit:20000000

    $Result = Invoke-Script

    $Result.Changed | Should -BeTrue
    Assert-Setting $Result.Result.settings[4] `
      'requestLimits.maxAllowedContentLength' `
      '20000000 explicit' '30000000 explicit' $True
    @($global:FakeIis.Writes) | Should -Be @(
      'S5:requestLimits.maxAllowedContentLength=30000000'
    )
    @($global:FakeIis.Mechanisms) | Should -Be @(
      'Add-Type:C:\Windows\system32\inetsrv\Microsoft.Web.Administration.dll'
      'New-Object:Microsoft.Web.Administration.ServerManager'
      'CommitChanges'
    )
  }

  It 'P8 writes the limit when its desired value is inherited' {
    Reset-FakeIis -LimitInherited:$True

    $Result = Invoke-Script

    $Result.Changed | Should -BeTrue
    Assert-Setting $Result.Result.settings[4] `
      'requestLimits.maxAllowedContentLength' `
      '30000000 inherited' '30000000 explicit' $True
    @($global:FakeIis.Writes) | Should -Be @(
      'S5:requestLimits.maxAllowedContentLength=30000000'
    )
  }

  It 'P9 reports full drift under WhatIf and check mode without writing' {
    Reset-FakeIis `
      -Validation:'SHA1' `
      -Timeout:([System.TimeSpan]'00:20:00') `
      -Headers:@('X-Powered-By') `
      -AllowHighBitCharacters:$True `
      -LimitInherited:$True

    $Result = Invoke-Script -WhatIf -CheckMode:$True

    $Result.CheckMode | Should -BeTrue
    $Result.Changed | Should -BeTrue
    $Result.Result.changed | Should -BeTrue
    Assert-Setting $Result.Result.settings[0] `
      'machineKey.validation' 'SHA1' 'SHA1' $True
    Assert-Setting $Result.Result.settings[1] `
      'sessionState.timeout' '00:20:00' '00:20:00' $True
    Assert-Setting $Result.Result.settings[2] `
      'customHeaders' 'X-Powered-By' 'X-Powered-By' $True
    Assert-Setting $Result.Result.settings[3] `
      'requestFiltering.allowHighBitCharacters' 'True' 'True' $True
    Assert-Setting $Result.Result.settings[4] `
      'requestLimits.maxAllowedContentLength' `
      '30000000 inherited' '30000000 inherited' $True
    $global:FakeIis.Writes.Count | Should -Be 0
    $global:FakeIis.Mechanisms.Count | Should -Be 0
  }

  It 'P10 refuses every invalid in-body value before import or read' {
    $Cases = @(
      [PSCustomObject]@{ Parameter = 'SessionTimeout'; Value = 'abc' }
      [PSCustomObject]@{ Parameter = 'SessionTimeout'; Value = '-00:01:00' }
      [PSCustomObject]@{ Parameter = 'SessionTimeout'; Value = '00:00:00' }
      [PSCustomObject]@{ Parameter = 'MachineKeyValidation'; Value = 'MD5' }
      [PSCustomObject]@{ Parameter = 'MaxAllowedContentLength'; Value = 0 }
      [PSCustomObject]@{ Parameter = 'RemoveResponseHeader'; Value = 'X Powered' }
    )

    ForEach ($Case In $Cases) {
      Reset-FakeIis
      $Override = @{}
      $Override[$Case.Parameter] = $Case.Value
      $ExpectedMessage = '*{0}*{1}*' -f $Case.Parameter, $Case.Value

      { Invoke-Script @Override } | Should -Throw -ExpectedMessage:$ExpectedMessage

      Assert-ResultKeys -Result:$global:Ansible.Result
      $global:Ansible.Result.msg | Should -BeLike $ExpectedMessage
      @($global:Ansible.Result.settings).Count | Should -Be 0
      $global:Ansible.Failed | Should -BeTrue
      $global:Ansible.Changed | Should -BeFalse
      $global:PublicationOrder | Should -Be @('result-before-failed')
      $global:FakeIis.Imports.Count | Should -Be 0
      $global:FakeIis.Reads.Count | Should -Be 0
      $global:FakeIis.Writes.Count | Should -Be 0
    }
  }

  It 'P11 publishes Result before Failed and rethrows a read failure' {
    Reset-FakeIis
    $global:FakeIis.ThrowOnRead = 'S1'

    { Invoke-Script } | Should -Throw -ExpectedMessage:'*S1 read failed*'

    Assert-ResultKeys -Result:$global:Ansible.Result
    $global:PublicationOrder | Should -Be @('result-before-failed')
    $global:Ansible.Failed | Should -BeTrue
    $global:Ansible.Changed | Should -BeFalse
    $global:Ansible.Result.changed | Should -BeFalse
    @($global:Ansible.Result.settings).Count | Should -Be 0
    $global:Ansible.Result.msg | Should -Be 'S1 read failed'
    @($global:FakeIis.Reads) | Should -Be @('S1')
    $global:FakeIis.Writes.Count | Should -Be 0
  }

  It 'P12 publishes only completed S1 after its write then an S2 write failure' {
    Reset-FakeIis `
      -Validation:'SHA1' `
      -Timeout:([System.TimeSpan]'00:30:00')
    $global:FakeIis.ThrowOnWrite = 'S2'

    { Invoke-Script } | Should -Throw -ExpectedMessage:'*S2 write failed*'

    Assert-ResultKeys -Result:$global:Ansible.Result
    $global:PublicationOrder | Should -Be @('result-before-failed')
    $global:Ansible.Failed | Should -BeTrue
    $global:Ansible.Changed | Should -BeTrue
    $global:Ansible.Result.changed | Should -BeTrue
    @($global:Ansible.Result.settings).Count | Should -Be 1
    Assert-Setting $global:Ansible.Result.settings[0] `
      'machineKey.validation' 'SHA1' 'HMACSHA256' $True
    $global:Ansible.Result.msg | Should -Be 'S2 write failed'
    @($global:FakeIis.Writes) | Should -Be @(
      'S1:machineKey.validation=HMACSHA256'
      'S2:sessionState.timeout=00:15:00'
    )
  }
}
