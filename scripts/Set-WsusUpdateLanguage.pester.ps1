#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Specification for Set-WsusUpdateLanguage.ps1.

    .DESCRIPTION
        Runs anywhere, Linux CI included. The script's only platform call is Get-WsusServer, which
        is a cmdlet rather than a static type call precisely so a function declared here can stand
        in for it. That is the whole reason the script does not use the AdminProxy static the
        WID-era role used.

        The stub models the one behaviour that matters and is easy to get wrong: the configuration
        object is a CLIENT-SIDE CACHE. GetConfiguration returns a fresh view built from the stub's
        committed state, Save is what commits, and $global:FakeSaveDrops* let a test model a
        server that accepts the call and keeps nothing. Without that, a script could "verify" its
        own unsaved assignments and pass.

        Stub state lives in $global: variables because inside a function called from a child
        SCRIPT, $script: resolves to the child's scope, not this file's.
#>

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-WsusUpdateLanguage.ps1'

  $script:Invoke = {
    & $script:ScriptPath -Language 'en'
  }

  # win_powershell passes -WhatIf as well as setting CheckMode, because the script declares
  # SupportsShouldProcess. Only this invoker reproduces the second half.
  $script:InvokeWhatIf = {
    & $script:ScriptPath -Language 'en' -WhatIf
  }

  Function Get-WsusServer {
    [CmdletBinding()]
    Param ()

    If ($global:FakeServerNull) { Return $Null }

    $Server = [PSCustomObject]@{}
    $Server | Add-Member -MemberType ScriptMethod -Name 'GetConfiguration' -Value {
      $global:FakeGetConfigurationCalls++

      $Configuration = [PSCustomObject]@{
        AllUpdateLanguagesEnabled = $global:FakeAllEnabled
      }
      $Configuration | Add-Member -MemberType ScriptMethod -Name 'GetEnabledUpdateLanguages' -Value {
        , @($global:FakeLanguages)
      }
      $Configuration | Add-Member -MemberType ScriptMethod -Name 'SetEnabledUpdateLanguages' -Value {
        Param ($Collection)
        $global:FakeSetCalls++
        $global:FakePending = @($Collection)
      }
      $Configuration | Add-Member -MemberType ScriptMethod -Name 'Save' -Value {
        $global:FakeSaveCalls++
        If ($global:FakeSaveDropsFlag -eq $False) {
          $global:FakeAllEnabled = $this.AllUpdateLanguagesEnabled
        }
        If ($global:FakeSaveDropsLanguages -eq $False) {
          $global:FakeLanguages = @($global:FakePending)
        }
      }
      Return $Configuration
    }
    Return $Server
  }
}

Describe 'Set-WsusUpdateLanguage' {

  BeforeEach {
    $global:FakeServerNull = $false
    $global:FakeAllEnabled = $true
    $global:FakeLanguages = @()
    $global:FakePending = @()
    $global:FakeSetCalls = 0
    $global:FakeSaveCalls = 0
    $global:FakeGetConfigurationCalls = 0
    $global:FakeSaveDropsFlag = $false
    $global:FakeSaveDropsLanguages = $false
    $global:Ansible = [PSCustomObject]@{ Changed = $true; CheckMode = $false; Result = $null }
  }

  Context 'the restriction itself' {

    # The flag OVERRIDES the list, so clearing it is not optional housekeeping -- a server with
    # the right list and the flag still set synchronises every language regardless.
    It 'clears the all-languages flag and writes the declared set' {
      $null = & $script:Invoke
      $Result = $global:Ansible.Result

      $global:FakeAllEnabled | Should -BeFalse
      @($global:FakeLanguages) | Should -Be @('en')
      $Result.changed | Should -BeTrue
      $Result.all_languages_enabled | Should -BeFalse
    }

    It 'reports the change on the transport object, not only in its own result' {
      $null = & $script:Invoke

      $global:Ansible.Changed | Should -BeTrue
    }

    It 'writes nothing when the server already holds the declared set' {
      $global:FakeAllEnabled = $false
      $global:FakeLanguages = @('en')

      $null = & $script:Invoke
      $Result = $global:Ansible.Result

      $global:FakeSaveCalls | Should -Be 0
      $Result.changed | Should -BeFalse
      $global:Ansible.Changed | Should -BeFalse
    }

    # The server returns the set in its own casing and order. Comparing raw sequences would
    # rewrite a configuration that already matched, on every converge.
    It 'treats casing and order as equivalent rather than as a change' {
      $global:FakeAllEnabled = $false
      $global:FakeLanguages = @('FR', 'EN')

      $null = & $script:ScriptPath -Language 'en', 'fr'
      $Result = $global:Ansible.Result

      $global:FakeSaveCalls | Should -Be 0
      $Result.changed | Should -BeFalse
    }

    # The list can be right while the flag still makes it meaningless.
    It 'still writes when the list matches but the all-languages flag is set' {
      $global:FakeAllEnabled = $true
      $global:FakeLanguages = @('en')

      $null = & $script:Invoke
      $Result = $global:Ansible.Result

      $global:FakeSaveCalls | Should -Be 1
      $Result.changed | Should -BeTrue
    }

    It 'writes when the flag is clear but the list is wrong' {
      $global:FakeAllEnabled = $false
      $global:FakeLanguages = @('fr')

      $null = & $script:Invoke

      @($global:FakeLanguages) | Should -Be @('en')
    }

    It 'normalises the request before comparing, so duplicates and padding are not a change' {
      $global:FakeAllEnabled = $false
      $global:FakeLanguages = @('en')

      $null = & $script:ScriptPath -Language 'EN', ' en ', 'en'
      $Result = $global:Ansible.Result

      $global:FakeSaveCalls | Should -Be 0
      $Result.changed | Should -BeFalse
    }
  }

  Context 'the write is verified against the server, not against itself' {

    # The configuration object is a client-side cache: assigning to it and calling Save updates
    # the local copy whether or not the server kept anything. A script that trusted its own
    # object would pass here while the host stayed unrestricted.
    It 'fails when the server keeps reporting the all-languages flag' {
      $global:FakeSaveDropsFlag = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*did not persist*'
    }

    # A Save that took, followed by a verification that failed, is still a changed host. Reporting
    # otherwise would tell an operator the server was untouched while its flag is already cleared.
    # Without this the mutation is invisible: deleting the mid-write assignment leaves the rest of
    # this suite green.
    It 'reports the change when the write took and the verification then failed' {
      $global:FakeSaveDropsLanguages = $true

      { & $script:Invoke } | Should -Throw

      $global:Ansible.Changed | Should -BeTrue
    }

    It 'fails when the server keeps a different language set' {
      $global:FakeSaveDropsLanguages = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*not the declared*'
    }

    It 'reads the server again rather than reusing the handle it wrote through' {
      $null = & $script:Invoke

      $global:FakeGetConfigurationCalls | Should -BeGreaterThan 1
    }
  }

  Context 'the transport contract' {

    It 'declares SupportsShouldProcess, which is what makes the module run it under --check' {
      $Command = Get-Command -Name $script:ScriptPath
      $Command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }

    It 'writes nothing under -WhatIf' {
      $null = & $script:InvokeWhatIf

      $global:FakeSaveCalls | Should -Be 0
      $global:FakeSetCalls | Should -Be 0
    }

    # The need is real even when the deed is suppressed; reporting no change would tell an
    # operator running --check that an unrestricted server needs nothing.
    It 'still reports a change under -WhatIf, because the host needs one' {
      $null = & $script:InvokeWhatIf
      $Result = $global:Ansible.Result

      $Result.changed | Should -BeTrue
    }
  }

  Context 'refusals' {

    It 'refuses a host where WSUS post-installation has not produced a server' {
      $global:FakeServerNull = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*post-installation*'
    }

    # ValidateNotNullOrEmpty accepts an array of blanks; normalisation is what catches it.
    It 'refuses a language set that normalises away to nothing' {
      { & $script:ScriptPath -Language ' ', '   ' } | Should -Throw -ExpectedMessage '*synchronise nothing*'
    }
  }
}
