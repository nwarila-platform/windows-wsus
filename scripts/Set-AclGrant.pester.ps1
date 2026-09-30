#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Specification for Set-AclGrant.ps1.

    .DESCRIPTION
        Runs anywhere, Linux CI included. FileSystemAccessRule and SecurityIdentifier cannot be
        CONSTRUCTED off Windows and Set-Acl does not exist there, which is exactly why the script
        reaches them through New-Object and cmdlets rather than type casts -- everything it touches
        can be stood in for here.

        The stub models a security descriptor as state, not as a return value: PurgeAccessRules
        removes the explicit entries for an identity, AddAccessRule appends, and Set-Acl commits
        the object to $global:FakeCommitted. That is what lets the tests distinguish a script that
        wrote from one that merely built an object, and lets a test model a filesystem that accepts
        the call and keeps nothing.

        Stub state lives in $global: variables because inside a function called from a child
        SCRIPT, $script: resolves to the child's scope, not this file's.
#>

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-AclGrant.ps1'
  $script:NetworkService = 'S-1-5-20'
  $script:FullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
  $script:WriteData = [System.Security.AccessControl.FileSystemRights]::WriteData
  $script:Allow = [System.Security.AccessControl.AccessControlType]::Allow
  $script:Deny = [System.Security.AccessControl.AccessControlType]::Deny

  $script:ReadAndExecute = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
  $script:Synchronize = [System.Security.AccessControl.FileSystemRights]::Synchronize

  # Propagation defaults to None because that is what Windows writes and what every converged test
  # means. It is a parameter so a test can model the InheritOnly entry that carries the right flags
  # and grants nothing on the path itself.
  $script:NewAce = {
    Param ($AceSid, $AceRights, $AceType, $AceInherited, $AceFlags, $AcePropagation = 'None')

    $Identity = [PSCustomObject]@{ Value = $AceSid }
    $Identity | Add-Member -MemberType ScriptMethod -Name 'Translate' -Value {
      Param ($TargetType)
      Return [PSCustomObject]@{ Value = $this.Value }
    }

    Return [PSCustomObject]@{
      IdentityReference = $Identity
      FileSystemRights  = $AceRights
      AccessControlType = $AceType
      IsInherited       = $AceInherited
      InheritanceFlags  = $AceFlags
      PropagationFlags  = $AcePropagation
    }
  }

  Function New-Object {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$TypeName, [Parameter()] [System.Object]$ArgumentList)

    Switch -Wildcard ($TypeName) {
      '*SecurityIdentifier' { Return [PSCustomObject]@{ Value = [System.String]$ArgumentList } }
      '*FileSystemAccessRule' {
        # Built inline rather than through the helper above: New-Object is called FROM the child
        # script, where $script: resolves to that script's scope and the helper is invisible. The
        # same trap this file's header records for stub state.
        $A = @($ArgumentList)
        $RuleIdentity = [PSCustomObject]@{ Value = [System.String]$A[0].Value }
        $RuleIdentity | Add-Member -MemberType ScriptMethod -Name 'Translate' -Value {
          Param ($TargetType)
          Return [PSCustomObject]@{ Value = $this.Value }
        }
        Return [PSCustomObject]@{
          IdentityReference = $RuleIdentity
          # Synchronize, because Windows adds it as it writes an allow. Measured on the target: a
          # rule created as ReadAndExecute (131241) reads back as 1179817. Without this the model
          # would let an exact-rights comparison pass that a real host would fail.
          FileSystemRights  = [System.Security.AccessControl.FileSystemRights](
            ([System.Int32][System.Security.AccessControl.FileSystemRights]$A[1]) -bor
            ([System.Int32][System.Security.AccessControl.FileSystemRights]::Synchronize)
          )
          AccessControlType = [System.Security.AccessControl.AccessControlType]$A[4]
          IsInherited       = $false
          InheritanceFlags  = [System.String]$A[2]
          PropagationFlags  = [System.String]$A[3]
        }
      }
      default { Throw ('Unexpected type: {0}' -f $TypeName) }
    }
  }

  Function Get-Acl {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$Path)

    $Acl = [PSCustomObject]@{ Access = @($global:FakeAces) }
    $Acl | Add-Member -MemberType ScriptMethod -Name 'PurgeAccessRules' -Value {
      Param ($Identity)
      $global:FakePurged++
      $global:FakeAces = @(@($global:FakeAces) | Where-Object {
        $_.IsInherited -or $_.IdentityReference.Value -ne $Identity.Value
      })
      $this.Access = @($global:FakeAces)
    }
    $Acl | Add-Member -MemberType ScriptMethod -Name 'AddAccessRule' -Value {
      Param ($Rule)
      If (-not $global:FakeWriteIgnored) { $global:FakeAces = @(@($global:FakeAces) + $Rule) }
      $this.Access = @($global:FakeAces)
    }
    Return $Acl
  }

  Function Set-Acl {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$Path, [Parameter()] [System.Object]$AclObject)

    $global:FakeCommitted++
  }

  $script:Invoke = {
    & $script:ScriptPath -Path 'F:\WSUS\WsusContent' -Sid 'S-1-5-20' -Rights 'FullControl' `
      -InheritanceFlags 'ContainerInherit, ObjectInherit'
  }
  # A second declaration, so a test can model an entry that grants MORE than was asked for. The
  # over-grant case cannot be written with FullControl, because nothing exceeds it.
  $script:InvokeReadOnly = {
    & $script:ScriptPath -Path 'F:\WSUS\WsusContent' -Sid 'S-1-5-20' -Rights 'ReadAndExecute' `
      -InheritanceFlags 'ContainerInherit, ObjectInherit'
  }
  $script:InvokeWhatIf = {
    & $script:ScriptPath -Path 'F:\WSUS\WsusContent' -Sid 'S-1-5-20' -Rights 'FullControl' `
      -InheritanceFlags 'ContainerInherit, ObjectInherit' -WhatIf
  }
}

Describe 'Set-AclGrant' {

  BeforeEach {
    $global:FakeAces = @()
    $global:FakePurged = 0
    $global:FakeCommitted = 0
    $global:FakeWriteIgnored = $false
    $global:Ansible = [PSCustomObject]@{ Changed = $true; CheckMode = $false; Result = $null }
  }

  Context 'the reason this exists instead of win_acl' {

    # win_acl adds an allow and leaves the deny. Windows evaluates deny first, so the grant is
    # still broken after a converge that reported changed.
    It 'removes an explicit deny that would otherwise survive an added allow' {
      $global:FakeAces = @(
        (& $script:NewAce $script:NetworkService $script:FullControl $script:Allow $false 'ContainerInherit, ObjectInherit')
        (& $script:NewAce $script:NetworkService $script:WriteData $script:Deny $false 'None')
      )

      $null = & $script:Invoke

      @(@($global:FakeAces) | Where-Object { $_.AccessControlType -eq $script:Deny }) | Should -BeNullOrEmpty
      $global:FakeCommitted | Should -Be 1
      $global:Ansible.Result.changed | Should -BeTrue
    }

    It 'reports how many explicit entries it replaced' {
      $global:FakeAces = @(
        (& $script:NewAce $script:NetworkService $script:FullControl $script:Allow $false 'ContainerInherit, ObjectInherit')
        (& $script:NewAce $script:NetworkService $script:WriteData $script:Deny $false 'None')
      )

      $null = & $script:Invoke

      $global:Ansible.Result.purged | Should -Be 2
    }

    It 'leaves other identities untouched' {
      $Other = 'S-1-5-32-545'
      $global:FakeAces = @(
        (& $script:NewAce $Other $script:FullControl $script:Allow $false 'None')
        (& $script:NewAce $script:NetworkService $script:WriteData $script:Deny $false 'None')
      )

      $null = & $script:Invoke

      @(@($global:FakeAces) | Where-Object { $_.IdentityReference.Value -eq $Other }) | Should -Not -BeNullOrEmpty
    }
  }

  Context 'what counts as already correct' {

    It 'writes nothing when the entry already grants the rights with the declared inheritance' {
      $global:FakeAces = @(
        (& $script:NewAce $script:NetworkService $script:FullControl $script:Allow $false 'ContainerInherit, ObjectInherit')
      )

      $null = & $script:Invoke

      $global:FakeCommitted | Should -Be 0
      $global:Ansible.Changed | Should -BeFalse
    }

    # InheritOnly carries the declared inheritance flags and grants nothing on the path itself --
    # children only. The service would hold no rights on the directory it has to write into, while
    # a flags-only comparison called the entry correct and reported no change.
    It 'rewrites an entry whose propagation is InheritOnly' {
      $global:FakeAces = @(
        (& $script:NewAce $script:NetworkService $script:FullControl $script:Allow $false 'ContainerInherit, ObjectInherit' 'InheritOnly')
      )

      $null = & $script:Invoke

      $global:FakeCommitted | Should -Be 1
      $global:Ansible.Result.changed | Should -BeTrue
    }

    # Two entries can OR together into the declared rights while neither is the entry this script
    # declares -- and the write replaces both with one, so calling this converged would report no
    # change on a state the next write still changes.
    It 'rewrites when several explicit entries only add up to the rights' {
      $global:FakeAces = @(
        (& $script:NewAce $script:NetworkService $script:ReadAndExecute $script:Allow $false 'ContainerInherit, ObjectInherit')
        (& $script:NewAce $script:NetworkService $script:FullControl $script:Allow $false 'ContainerInherit, ObjectInherit')
      )

      $null = & $script:Invoke

      $global:FakeCommitted | Should -Be 1
      @(@($global:FakeAces) | Where-Object { -not $_.IsInherited }) | Should -HaveCount 1
    }

    # This script declares the entry rather than adding to it, so an over-grant is drift too.
    It 'reduces an entry that grants more than was declared' {
      $global:FakeAces = @(
        (& $script:NewAce $script:NetworkService $script:FullControl $script:Allow $false 'ContainerInherit, ObjectInherit')
      )

      $null = & $script:InvokeReadOnly

      $global:FakeCommitted | Should -Be 1
      $global:Ansible.Result.changed | Should -BeTrue
    }

    # Windows adds Synchronize as it writes an allow, so the entry a converged host holds is the
    # declared rights PLUS that bit. Comparing against the declared value alone would find drift
    # here on every converge and rewrite a correct entry forever.
    It 'accepts the Synchronize bit Windows adds to a written allow' {
      $global:FakeAces = @(
        (& $script:NewAce $script:NetworkService ([System.Security.AccessControl.FileSystemRights](
          ([System.Int32]$script:ReadAndExecute) -bor ([System.Int32]$script:Synchronize)
        )) $script:Allow $false 'ContainerInherit, ObjectInherit')
      )

      $null = & $script:InvokeReadOnly

      $global:FakeCommitted | Should -Be 0
      $global:Ansible.Changed | Should -BeFalse
    }

    # A grant that does not reach the children is not the grant that was declared.
    It 'rewrites when the rights are right but the inheritance is not' {
      $global:FakeAces = @(
        (& $script:NewAce $script:NetworkService $script:FullControl $script:Allow $false 'None')
      )

      $null = & $script:Invoke

      $global:FakeCommitted | Should -Be 1
    }

    It 'rewrites when only an inherited allow covers the rights' {
      $global:FakeAces = @(
        (& $script:NewAce $script:NetworkService $script:FullControl $script:Allow $true 'ContainerInherit, ObjectInherit')
      )

      $null = & $script:Invoke

      $global:FakeCommitted | Should -Be 1
    }
  }

  Context 'what it refuses' {

    # An inherited deny belongs to the parent. Writing the allow and returning success would
    # report access this script cannot deliver.
    It 'refuses an inherited deny rather than reporting a grant it cannot make' {
      $global:FakeAces = @(
        (& $script:NewAce $script:NetworkService $script:WriteData $script:Deny $true 'ContainerInherit, ObjectInherit')
      )

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*inherited deny*'
      $global:FakeCommitted | Should -Be 0
    }

    # Set-Acl reports nothing about what the filesystem kept.
    It 'fails when the descriptor does not hold the grant afterwards' {
      $global:FakeWriteIgnored = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*does not grant*'
    }

    It 'still reports the change when the write took and the check then failed' {
      $global:FakeWriteIgnored = $true

      { & $script:Invoke } | Should -Throw

      $global:Ansible.Changed | Should -BeTrue
    }
  }

  Context 'the transport contract' {

    It 'declares SupportsShouldProcess, which is what makes the module run it under --check' {
      (Get-Command -Name $script:ScriptPath).Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }

    It 'writes nothing under -WhatIf' {
      $global:FakeAces = @(
        (& $script:NewAce $script:NetworkService $script:WriteData $script:Deny $false 'None')
      )

      $null = & $script:InvokeWhatIf

      $global:FakeCommitted | Should -Be 0
      $global:FakePurged | Should -Be 0
    }

    It 'still reports a change under -WhatIf, because the host needs one' {
      $global:FakeAces = @(
        (& $script:NewAce $script:NetworkService $script:WriteData $script:Deny $false 'None')
      )

      $null = & $script:InvokeWhatIf

      $global:Ansible.Result.changed | Should -BeTrue
    }
  }
}
