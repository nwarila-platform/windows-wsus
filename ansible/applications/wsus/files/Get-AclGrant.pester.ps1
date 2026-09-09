#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Specification for Get-AclGrant.ps1.

    .DESCRIPTION
        Runs anywhere, Linux CI included. The script's only platform call is Get-Acl, a cmdlet, so
        a function declared here stands in for it. The FileSystemRights and AccessControlType
        enums are real -- .NET carries them everywhere -- so the arithmetic under test is the
        arithmetic that will run on Windows, not a model of it.

        The stub builds entries the way Get-Acl really returns them: an IdentityReference that
        answers Translate with a SID, plus rights, an access control type, and IsInherited. The
        cases that matter are the ones a text search over icacls output gets wrong -- a deny that
        neutralises a present allow, an inherited grant standing in for an owned one, and a
        display name that is not the identity it looks like.

        Stub state lives in $global: variables because inside a function called from a child
        SCRIPT, $script: resolves to the child's scope, not this file's.
#>

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Get-AclGrant.ps1'
  $script:NetworkService = 'S-1-5-20'
  $script:Users = 'S-1-5-32-545'

  $script:FullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
  $script:ReadExecute = [System.Security.AccessControl.FileSystemRights]'ReadAndExecute, Synchronize'
  $script:WriteData = [System.Security.AccessControl.FileSystemRights]::WriteData

  # Shaped like a real FileSystemAccessRule: the identity answers Translate with a SID.
  $script:NewAce = {
    Param ($AceSid, $AceRights, $AceType, $AceInherited, $AceName)

    $Identity = [PSCustomObject]@{ Value = $AceSid }
    $Identity | Add-Member -MemberType ScriptMethod -Name 'Translate' -Value {
      Param ($TargetType)
      Return [PSCustomObject]@{ Value = $this.Value }
    }
    $Identity | Add-Member -MemberType ScriptMethod -Name 'ToString' -Value {
      Return $global:FakeNameFor[$this.Value]
    } -Force

    Return [PSCustomObject]@{
      IdentityReference = $Identity
      FileSystemRights  = $AceRights
      AccessControlType = $AceType
      IsInherited       = $AceInherited
      InheritanceFlags  = 'ContainerInherit, ObjectInherit'
    }
  }

  Function Get-Acl {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$Path)

    If ($global:FakeAclThrows) { Throw ('Cannot find path {0}' -f $Path) }
    Return [PSCustomObject]@{ Access = @($global:FakeAces) }
  }

  $script:Invoke = {
    Param ($TargetSid, $TargetRights)
    & $script:ScriptPath -Path 'F:\WSUS\WsusContent' -Sid $TargetSid -Rights $TargetRights
  }
}

Describe 'Get-AclGrant' {

  BeforeEach {
    $global:FakeAces = @()
    $global:FakeAclThrows = $false
    $global:FakeNameFor = @{ 'S-1-5-20' = 'NT AUTHORITY\NETWORK SERVICE'; 'S-1-5-32-545' = 'BUILTIN\Users' }
    $global:Ansible = [PSCustomObject]@{ Changed = $true; CheckMode = $false; Result = $null }
  }

  Context 'a deny that a text search cannot see' {

    # The defect this script exists for. icacls still prints the allow line, a search for it still
    # matches, and Windows still refuses the write because deny is evaluated first.
    It 'reports the deny when one intersects an otherwise sufficient allow' {
      $global:FakeAces = @(
        (& $script:NewAce $script:NetworkService $script:FullControl ([System.Security.AccessControl.AccessControlType]::Allow) $false)
        (& $script:NewAce $script:NetworkService $script:WriteData ([System.Security.AccessControl.AccessControlType]::Deny) $false)
      )

      $null = & $script:Invoke $script:NetworkService 'FullControl'

      $global:Ansible.Result.allow_explicit | Should -BeTrue
      $global:Ansible.Result.deny_intersects | Should -BeTrue
    }

    # Intersection, not coverage: one right inside the set is enough to break the grant.
    It 'treats a partial deny as intersecting, not as harmless' {
      $global:FakeAces = @(
        (& $script:NewAce $script:Users $script:ReadExecute ([System.Security.AccessControl.AccessControlType]::Allow) $false)
        (& $script:NewAce $script:Users ([System.Security.AccessControl.FileSystemRights]::ReadData) ([System.Security.AccessControl.AccessControlType]::Deny) $false)
      )

      $null = & $script:Invoke $script:Users 'ReadAndExecute'

      $global:Ansible.Result.deny_intersects | Should -BeTrue
    }

    It 'counts an inherited deny, which applies just as an explicit one does' {
      $global:FakeAces = @(
        (& $script:NewAce $script:NetworkService $script:FullControl ([System.Security.AccessControl.AccessControlType]::Allow) $false)
        (& $script:NewAce $script:NetworkService $script:WriteData ([System.Security.AccessControl.AccessControlType]::Deny) $true)
      )

      $null = & $script:Invoke $script:NetworkService 'FullControl'

      $global:Ansible.Result.deny_intersects | Should -BeTrue
    }

    It 'reports no deny when the only deny belongs to a different identity' {
      $global:FakeAces = @(
        (& $script:NewAce $script:NetworkService $script:FullControl ([System.Security.AccessControl.AccessControlType]::Allow) $false)
        (& $script:NewAce $script:Users $script:FullControl ([System.Security.AccessControl.AccessControlType]::Deny) $false)
      )

      $null = & $script:Invoke $script:NetworkService 'FullControl'

      $global:Ansible.Result.deny_intersects | Should -BeFalse
      $global:Ansible.Result.allow_explicit | Should -BeTrue
    }
  }

  Context 'explicit against inherited' {

    # An inherited grant is the parent's to withdraw. A caller that must OWN its access asks for
    # allow_explicit; one that only needs the access to exist takes allow_effective.
    It 'separates an inherited grant from an owned one' {
      $global:FakeAces = @(
        (& $script:NewAce $script:Users $script:ReadExecute ([System.Security.AccessControl.AccessControlType]::Allow) $true)
      )

      $null = & $script:Invoke $script:Users 'ReadAndExecute'

      $global:Ansible.Result.allow_effective | Should -BeTrue
      $global:Ansible.Result.allow_explicit | Should -BeFalse
    }

    It 'reports both true when the entry is written on the path itself' {
      $global:FakeAces = @(
        (& $script:NewAce $script:Users $script:ReadExecute ([System.Security.AccessControl.AccessControlType]::Allow) $false)
      )

      $null = & $script:Invoke $script:Users 'ReadAndExecute'

      $global:Ansible.Result.allow_effective | Should -BeTrue
      $global:Ansible.Result.allow_explicit | Should -BeTrue
    }

    It 'carries the inheritance flags of the owned entry, not of an inherited one' {
      $global:FakeAces = @(
        (& $script:NewAce $script:Users $script:ReadExecute ([System.Security.AccessControl.AccessControlType]::Allow) $false)
      )

      $null = & $script:Invoke $script:Users 'ReadAndExecute'

      $global:Ansible.Result.inheritance | Should -Be 'ContainerInherit, ObjectInherit'
    }
  }

  Context 'what counts as covering the rights' {

    # Coverage, not equality. The real host returns 'ReadAndExecute, Synchronize' where the role
    # asks for ReadAndExecute; an equality test would fail a correct ACL.
    It 'accepts an entry carrying more rights than were asked for' {
      $global:FakeAces = @(
        (& $script:NewAce $script:Users $script:FullControl ([System.Security.AccessControl.AccessControlType]::Allow) $false)
      )

      $null = & $script:Invoke $script:Users 'ReadAndExecute'

      $global:Ansible.Result.allow_explicit | Should -BeTrue
    }

    It 'refuses an entry missing part of what was asked for' {
      $global:FakeAces = @(
        (& $script:NewAce $script:NetworkService $script:ReadExecute ([System.Security.AccessControl.AccessControlType]::Allow) $false)
      )

      $null = & $script:Invoke $script:NetworkService 'FullControl'

      $global:Ansible.Result.allow_explicit | Should -BeFalse
      $global:Ansible.Result.allow_effective | Should -BeFalse
    }

    # Windows accumulates allow entries; so does this.
    It 'combines two partial allows that together cover the rights' {
      $global:FakeAces = @(
        (& $script:NewAce $script:Users ([System.Security.AccessControl.FileSystemRights]::ReadData) ([System.Security.AccessControl.AccessControlType]::Allow) $false)
        (& $script:NewAce $script:Users $script:ReadExecute ([System.Security.AccessControl.AccessControlType]::Allow) $false)
      )

      $null = & $script:Invoke $script:Users 'ReadAndExecute'

      $global:Ansible.Result.allow_explicit | Should -BeTrue
    }

    It 'reports nothing granted when the identity has no entry at all' {
      $global:FakeAces = @(
        (& $script:NewAce $script:Users $script:FullControl ([System.Security.AccessControl.AccessControlType]::Allow) $false)
      )

      $null = & $script:Invoke $script:NetworkService 'FullControl'

      $global:Ansible.Result.allow_effective | Should -BeFalse
      $global:Ansible.Result.deny_intersects | Should -BeFalse
      $global:Ansible.Result.identities | Should -BeNullOrEmpty
    }
  }

  Context 'it reads and nothing more' {

    It 'never reports a change' {
      $global:FakeAces = @(
        (& $script:NewAce $script:Users $script:ReadExecute ([System.Security.AccessControl.AccessControlType]::Allow) $false)
      )

      $null = & $script:Invoke $script:Users 'ReadAndExecute'

      $global:Ansible.Changed | Should -BeFalse
    }

    It 'fails loudly when the path cannot be read, rather than reporting no grant' {
      $global:FakeAclThrows = $true

      { & $script:Invoke $script:Users 'ReadAndExecute' } | Should -Throw
    }
  }
}
