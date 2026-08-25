#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Set-DiskOnlineState.ps1 (org pair convention: every script
    ships with a sibling <Name>.pester.ps1; the pester-matrix workflow runs one
    leg per pair).

    Runs anywhere, Linux CI included: Get-Disk and Set-Disk are Windows storage
    cmdlets that do not exist on other platforms, so the script confines every
    platform call to those two and this file stubs them around an in-memory disk
    table. That exercises the whole decision surface -- observe, decide, apply,
    verify, refuse -- with no storage stack at all.

    Stub state lives in $global: variables because inside a function called from
    a child SCRIPT, $script: resolves to the child script's own scope, not this
    file's.

    Both transports are asserted: the standalone JSON emission and the $Ansible
    path via the inline context below (pairs are self-contained; no imports).
    Its Changed defaults to $True exactly like win_powershell -- so the spec
    proves the script SETS Changed rather than inheriting a default.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-DiskOnlineState.ps1'

  # Inline $Ansible stand-in (org contract: pairs are self-contained, no
  # imports). Faithful to win_powershell: Changed defaults to $True, and only
  # the ratified surface (Changed, CheckMode, Failed, Result) is modeled.
  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{
      Changed   = $True
      CheckMode = $CheckMode.IsPresent
      Failed    = $False
      Result    = $Null
    }
    $global:Ansible
  }

  Function Remove-AnsibleContext {
    Remove-Variable -Name 'Ansible' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  # In-memory disk table. $global:FakeDisks is the attached set; Set-Disk mutates
  # it -- unless the spec sets $global:FakeWriteIgnored, which models a platform
  # that silently reverts and is exactly the failure the script's verify exists
  # for. $global:SetCalls records every write so check mode can be proven silent.
  Function New-FakeDisk {
    Param (
      [System.Int32]$Number,
      [System.String]$UniqueId,
      [System.Boolean]$IsOffline = $False,
      [System.Boolean]$IsReadOnly = $False
    )
    [PSCustomObject]@{
      Number     = $Number
      UniqueId   = $UniqueId
      IsOffline  = $IsOffline
      IsReadOnly = $IsReadOnly
    }
  }

  Function Get-Disk {
    [CmdletBinding()]
    Param (
      [Parameter()] [System.Int32]$Number = -1
    )
    If ($Number -ge 0) {
      Return @($global:FakeDisks | Where-Object { $_.Number -eq $Number })
    }
    Return @($global:FakeDisks)
  }

  Function Set-Disk {
    [CmdletBinding()]
    Param (
      [Parameter()] [System.Int32]$Number,
      [Parameter()] [System.Object]$IsOffline,
      [Parameter()] [System.Object]$IsReadOnly
    )
    $global:SetCalls += 1
    If ($global:FakeWriteIgnored) { Return }
    $Target = $global:FakeDisks | Where-Object { $_.Number -eq $Number }
    # Windows refuses to bring a read-only disk online, so the fake refuses too. Without this
    # the ordering test passes whichever order the script writes in.
    If ($Null -ne $IsOffline -and -not [System.Boolean]$IsOffline -and $Target.IsReadOnly) {
      Throw 'cannot bring a read-only disk online'
    }
    If ($Null -ne $IsOffline) { $Target.IsOffline = [System.Boolean]$IsOffline }
    If ($Null -ne $IsReadOnly) { $Target.IsReadOnly = [System.Boolean]$IsReadOnly }
  }

  Function Reset-FakeStorage {
    $global:FakeWriteIgnored = $False
    $global:SetCalls = 0
    $global:FakeDisks = @(
      New-FakeDisk -Number 1 -UniqueId 'vol0aaa' -IsOffline $False -IsReadOnly $False
      New-FakeDisk -Number 2 -UniqueId 'vol0bbb' -IsOffline $False -IsReadOnly $False
    )
  }
}

Describe 'Set-DiskOnlineState' {

  AfterEach {
    Remove-AnsibleContext
  }

  Context 'a converged host' {
    BeforeEach { Reset-FakeStorage }

    It 'reports no change when every declared disk is already online and writable' {
      $Context = New-AnsibleContext
      & $script:ScriptPath -UniqueId @('vol0aaa', 'vol0bbb')
      $Context.Changed | Should -BeFalse
      $Context.Result.requested | Should -Be 2
      $Context.Result.msg | Should -Match 'already online and writable'
      $global:SetCalls | Should -Be 0
    }

    It 'SETS Changed rather than inheriting the transport default of true' {
      $Context = New-AnsibleContext
      $Context.Changed | Should -BeTrue
      & $script:ScriptPath -UniqueId @('vol0aaa')
      $Context.Changed | Should -BeFalse
    }
  }

  Context 'disks needing transition' {
    BeforeEach { Reset-FakeStorage }

    It 'brings an offline disk online and reports the change' {
      ($global:FakeDisks | Where-Object { $_.Number -eq 1 }).IsOffline = $True
      $Context = New-AnsibleContext
      & $script:ScriptPath -UniqueId @('vol0aaa')
      $Context.Changed | Should -BeTrue
      ($global:FakeDisks | Where-Object { $_.Number -eq 1 }).IsOffline | Should -BeFalse
      $Context.Result.disks[0].was_offline | Should -BeTrue
    }

    It 'clears a read-only disk and reports the change' {
      ($global:FakeDisks | Where-Object { $_.Number -eq 1 }).IsReadOnly = $True
      $Context = New-AnsibleContext
      & $script:ScriptPath -UniqueId @('vol0aaa')
      $Context.Changed | Should -BeTrue
      ($global:FakeDisks | Where-Object { $_.Number -eq 1 }).IsReadOnly | Should -BeFalse
      $Context.Result.disks[0].was_readonly | Should -BeTrue
    }

    It 'clears read-only before bringing online, so an offline read-only disk converges' {
      $Disk = $global:FakeDisks | Where-Object { $_.Number -eq 1 }
      $Disk.IsOffline = $True
      $Disk.IsReadOnly = $True
      $Context = New-AnsibleContext
      & $script:ScriptPath -UniqueId @('vol0aaa')
      $Disk.IsOffline | Should -BeFalse
      $Disk.IsReadOnly | Should -BeFalse
      $Context.Result.msg | Should -Match '1 of 1'
    }

    It 'counts only the disks that actually moved' {
      ($global:FakeDisks | Where-Object { $_.Number -eq 2 }).IsOffline = $True
      $Context = New-AnsibleContext
      & $script:ScriptPath -UniqueId @('vol0aaa', 'vol0bbb')
      $Context.Result.msg | Should -Match '1 of 2'
    }
  }

  Context 'fail-closed identity' {
    BeforeEach { Reset-FakeStorage }

    # The inline win_shell predecessor skipped an unmatched id in silence: Where-Object
    # returned nothing and the property reads against $Null yielded $Null.
    It 'refuses a declared id that matches no attached disk' {
      { & $script:ScriptPath -UniqueId @('vol0aaa', 'vol0missing') } |
        Should -Throw -ExpectedMessage '*found 0*'
    }

    # LogLevel can set WarningPreference to Stop. The trap's own Write-Warning then throws and
    # the operator gets an ActionPreferenceStopException instead of the failure it describes.
    It 'reports the original failure even when warnings are configured to stop' {
      $Caught = $Null
      Try { & $script:ScriptPath -UniqueId @('vol0missing') -LogLevel '222120' } Catch { $Caught = $PSItem }
      $Caught | Should -Not -BeNullOrEmpty
      # The wrapper's message quotes the original, so only the type distinguishes them.
      $Caught.Exception.GetType().FullName |
        Should -Not -Be 'System.Management.Automation.ActionPreferenceStopException'
      $Caught.Exception.Message | Should -BeLike '*found 0*'
    }

    It 'refuses an id that matches more than one attached disk' {
      $global:FakeDisks += New-FakeDisk -Number 3 -UniqueId 'vol0aaa'
      { & $script:ScriptPath -UniqueId @('vol0aaa') } |
        Should -Throw -ExpectedMessage '*found 2*'
    }

    It 'refuses repeated ids, which would make the per-disk detail ambiguous' {
      { & $script:ScriptPath -UniqueId @('vol0aaa', 'vol0aaa') } |
        Should -Throw -ExpectedMessage '*repeated entries*'
    }

    It 'refuses an all-whitespace request rather than reporting a vacuous success' {
      { & $script:ScriptPath -UniqueId @('   ') } |
        Should -Throw -ExpectedMessage '*no non-empty entries*'
    }
  }

  Context 'verification' {
    BeforeEach { Reset-FakeStorage }

    # A disk the platform puts straight back offline would otherwise report changed on
    # every converge and never converge.
    It 'fails when a transition does not take' {
      ($global:FakeDisks | Where-Object { $_.Number -eq 1 }).IsOffline = $True
      $global:FakeWriteIgnored = $True
      { & $script:ScriptPath -UniqueId @('vol0aaa') } |
        Should -Throw -ExpectedMessage '*read back*'
    }
  }

  Context 'check mode' {
    BeforeEach { Reset-FakeStorage }

    It 'decides the same change without writing' {
      ($global:FakeDisks | Where-Object { $_.Number -eq 1 }).IsOffline = $True
      $Context = New-AnsibleContext -CheckMode
      & $script:ScriptPath -UniqueId @('vol0aaa')
      $Context.Changed | Should -BeTrue
      $Context.Result.msg | Should -Match 'would be brought online'
      $global:SetCalls | Should -Be 0
      ($global:FakeDisks | Where-Object { $_.Number -eq 1 }).IsOffline | Should -BeTrue
    }
  }

  Context 'standalone transport' {
    BeforeEach { Reset-FakeStorage }

    It 'emits the result as JSON when no transport context exists' {
      Remove-AnsibleContext
      $Output = & $script:ScriptPath -UniqueId @('vol0aaa') | Out-String
      $Parsed = $Output | ConvertFrom-Json
      $Parsed.requested | Should -Be 1
      $Parsed.changed | Should -BeFalse
    }
  }
}
