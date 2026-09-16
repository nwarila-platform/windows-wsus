#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Specification for Set-WsusUpstream.ps1.

    .DESCRIPTION
        Runs anywhere, Linux CI included. The script's only platform call is Get-WsusServer, a
        cmdlet, so a function declared here stands in for it.

        The stub models the configuration as a CLIENT-SIDE CACHE, which is the behaviour the
        script exists to defend against: assignments land on the object immediately, and only
        Save() commits them to the stub's server state. $global:FakeSaveDrops lets a test model a
        server that accepts the call and keeps nothing -- without that, a script could verify its
        own unsaved assignments and pass while the host stayed pointed at Microsoft Update.

        Stub state lives in $global: variables because inside a function called from a child
        SCRIPT, $script: resolves to the child's scope, not this file's.
#>

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-WsusUpstream.ps1'

  Function Get-WsusServer {
    [CmdletBinding()]
    Param ()

    If ($global:FakeServerNull) { Return $Null }

    $Server = [PSCustomObject]@{}
    $Server | Add-Member -MemberType ScriptMethod -Name 'GetConfiguration' -Value {
      $c = [PSCustomObject]@{
        SyncFromMicrosoftUpdate      = $global:FakeSyncFromMU
        UpstreamWsusServerName       = $global:FakeUpstream
        UpstreamWsusServerPortNumber = $global:FakePort
        UpstreamWsusServerUseSsl     = $global:FakeSsl
        IsReplicaServer              = $global:FakeReplica
      }
      $c | Add-Member -MemberType ScriptMethod -Name 'Save' -Value {
        $global:FakeSaveCalls++
        If (-not $global:FakeSaveDrops) {
          $global:FakeSyncFromMU = $this.SyncFromMicrosoftUpdate
          $global:FakeUpstream   = $this.UpstreamWsusServerName
          $global:FakePort       = $this.UpstreamWsusServerPortNumber
          $global:FakeSsl        = $this.UpstreamWsusServerUseSsl
          $global:FakeReplica    = $this.IsReplicaServer
        }
      }
      Return $c
    }
    $Server | Add-Member -MemberType ScriptMethod -Name 'GetSubscription' -Value {
      $s = [PSCustomObject]@{}
      $s | Add-Member -MemberType ScriptMethod -Name 'GetSynchronizationStatus' -Value {
        If ($global:FakeSyncRunning) { Return 'Running' }
        Return 'NotProcessing'
      }
      $s | Add-Member -MemberType ScriptMethod -Name 'StopSynchronization' -Value {
        $global:FakeStopCalls++
        If (-not $global:FakeSyncWillNotStop) { $global:FakeSyncRunning = $false }
      }
      Return $s
    }
    Return $Server
  }

  $script:Invoke = {
    & $script:ScriptPath -UpstreamUrl 'http://192.0.2.6:8530' -Replica $true
  }
  $script:InvokeWhatIf = {
    & $script:ScriptPath -UpstreamUrl 'http://192.0.2.6:8530' -Replica $true -WhatIf
  }
}

Describe 'Set-WsusUpstream' {

  BeforeEach {
    $global:FakeSyncFromMU = $true
    $global:FakeUpstream = ''
    $global:FakePort = 8530
    $global:FakeSsl = $false
    $global:FakeReplica = $false
    $global:FakeSaveCalls = 0
    $global:FakeStopCalls = 0
    $global:FakeSaveDrops = $false
    $global:FakeSyncRunning = $false
    $global:FakeSyncWillNotStop = $false
    $global:FakeServerNull = $false
    $global:Ansible = [PSCustomObject]@{ Changed = $true; CheckMode = $false; Result = $null }
  }

  Context 'pointing at an upstream' {

    It 'clears Microsoft Update and records the upstream' {
      $null = & $script:Invoke

      $global:FakeSyncFromMU | Should -BeFalse
      $global:FakeUpstream | Should -Be '192.0.2.6'
      $global:Ansible.Result.changed | Should -BeTrue
    }

    # A replica inherits the upstream's approvals, which is what lets an update approved upstream
    # arrive already approved here.
    It 'sets replica mode' {
      $null = & $script:Invoke

      $global:FakeReplica | Should -BeTrue
    }

    It 'writes nothing when all five already match' {
      $global:FakeSyncFromMU = $false
      $global:FakeUpstream = '192.0.2.6'
      $global:FakeReplica = $true

      $null = & $script:Invoke

      $global:FakeSaveCalls | Should -Be 0
      $global:Ansible.Changed | Should -BeFalse
    }

    # The name being right while SyncFromMicrosoftUpdate is still true means the upstream is
    # recorded and ignored -- the exact half-configured state that looks correct in the console.
    It 'still writes when the name matches but Microsoft Update is still the source' {
      $global:FakeSyncFromMU = $true
      $global:FakeUpstream = '192.0.2.6'
      $global:FakeReplica = $true

      $null = & $script:Invoke

      $global:FakeSaveCalls | Should -Be 1
    }

    It 'writes when only the replica flag differs' {
      $global:FakeSyncFromMU = $false
      $global:FakeUpstream = '192.0.2.6'
      $global:FakeReplica = $false

      $null = & $script:Invoke

      $global:FakeSaveCalls | Should -Be 1
      $global:FakeReplica | Should -BeTrue
    }

    # The three below are each converged except for one field. A host already pointed at some OTHER
    # downstream has SyncFromMicrosoftUpdate false, so no other clause fires to carry the write --
    # only the field itself can notice, and re-pointing an existing downstream is the common case.
    It 'writes when only the upstream name differs' {
      $global:FakeSyncFromMU = $false
      $global:FakeUpstream = '192.0.2.9'
      $global:FakeReplica = $true

      $null = & $script:Invoke

      $global:FakeSaveCalls | Should -Be 1
      $global:FakeUpstream | Should -Be '192.0.2.6'
    }

    It 'writes when only the upstream port differs' {
      $global:FakeSyncFromMU = $false
      $global:FakeUpstream = '192.0.2.6'
      $global:FakePort = 8531
      $global:FakeReplica = $true

      $null = & $script:Invoke

      $global:FakeSaveCalls | Should -Be 1
      $global:FakePort | Should -Be 8530
    }

    It 'writes when only the upstream SSL flag differs' {
      $global:FakeSyncFromMU = $false
      $global:FakeUpstream = '192.0.2.6'
      $global:FakeSsl = $true
      $global:FakeReplica = $true

      $null = & $script:Invoke

      $global:FakeSaveCalls | Should -Be 1
      $global:FakeSsl | Should -BeFalse
    }
  }

  Context 'a synchronisation in flight' {

    # The running sync is still talking to the OLD source; saving underneath it leaves the server
    # in a state neither configuration describes.
    It 'stops a running synchronisation before saving' {
      $global:FakeSyncRunning = $true

      $null = & $script:Invoke

      $global:FakeStopCalls | Should -Be 1
      $global:FakeSaveCalls | Should -Be 1
    }

    It 'refuses rather than saving underneath a sync that will not stop' {
      $global:FakeSyncRunning = $true
      $global:FakeSyncWillNotStop = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*would not stop*'
      $global:FakeSaveCalls | Should -Be 0
    }
  }

  Context 'the write is verified against the server' {

    It 'fails when the server keeps none of it' {
      $global:FakeSaveDrops = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*did not persist*'
    }

    It 'still reports the change when the write took and the check then failed' {
      $global:FakeSaveDrops = $true

      { & $script:Invoke } | Should -Throw

      $global:Ansible.Changed | Should -BeTrue
    }
  }

  Context 'refusals and the transport contract' {

    It 'refuses a host where WSUS post-installation has not produced a server' {
      $global:FakeServerNull = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*post-installation*'
    }

    It 'declares SupportsShouldProcess, which is what makes the module run it under --check' {
      (Get-Command -Name $script:ScriptPath).Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }

    It 'writes nothing under -WhatIf' {
      $null = & $script:InvokeWhatIf

      $global:FakeSaveCalls | Should -Be 0
    }

    It 'still reports a change under -WhatIf, because the host needs one' {
      $null = & $script:InvokeWhatIf

      $global:Ansible.Result.changed | Should -BeTrue
    }
  }

  Context 'The upstream URL is taken apart before anything is written' {

    It 'derives host, port and transport from the URL' {
      $global:FakeSyncFromMU = $true
      & $script:ScriptPath -UpstreamUrl 'https://wsus.example.com:8531' -Replica $true
      $global:FakeUpstream | Should -Be 'wsus.example.com'
      $global:FakePort     | Should -Be 8531
      $global:FakeSsl      | Should -BeTrue
    }

    It 'reads http as a plain link rather than an encrypted one' {
      $global:FakeSyncFromMU = $true
      & $script:ScriptPath -UpstreamUrl 'http://wsus.example.com:8530' -Replica $true
      $global:FakeSsl | Should -BeFalse
    }

    It 'tolerates a trailing slash' {
      $global:FakeSyncFromMU = $true
      & $script:ScriptPath -UpstreamUrl 'http://192.0.2.6:8530/' -Replica $true
      $global:FakeUpstream | Should -Be '192.0.2.6'
      $global:FakePort     | Should -Be 8530
    }

    It 'refuses a URL that names no port, rather than letting one be invented' {
      { & $script:ScriptPath -UpstreamUrl 'http://wsus.example.com' -Replica $true } |
        Should -Throw -ExpectedMessage '*names no port*'
    }

    It 'accepts an explicitly written 80, because which port is sensible is not its call' {
      $global:FakeSyncFromMU = $true
      & $script:ScriptPath -UpstreamUrl 'http://wsus.example.com:80' -Replica $true
      $global:FakePort | Should -Be 80
    }

    It 'accepts an explicitly written 443 over https for the same reason' {
      $global:FakeSyncFromMU = $true
      & $script:ScriptPath -UpstreamUrl 'https://wsus.example.com:443' -Replica $true
      $global:FakePort | Should -Be 443
      $global:FakeSsl  | Should -BeTrue
    }

    It 'refuses port 0, which Uri accepts and nothing can dial' {
      { & $script:ScriptPath -UpstreamUrl 'http://wsus.example.com:0' -Replica $true } |
        Should -Throw -ExpectedMessage '*between 1 and 65535*'
    }

    It 'accepts the top of the range' {
      $global:FakeSyncFromMU = $true
      & $script:ScriptPath -UpstreamUrl 'http://wsus.example.com:65535' -Replica $true
      $global:FakePort | Should -Be 65535
    }

    It 'refuses a scheme WSUS is not reached over' {
      { & $script:ScriptPath -UpstreamUrl 'ftp://wsus.example.com:8530' -Replica $true } |
        Should -Throw -ExpectedMessage "*scheme 'ftp'*"
    }

    It 'refuses a bare host and port, which is not an absolute URL' {
      { & $script:ScriptPath -UpstreamUrl '192.0.2.6:8530' -Replica $true } |
        Should -Throw -ExpectedMessage '*not an absolute URL*'
    }

    It 'writes nothing when the URL is malformed' {
      $global:FakeSyncFromMU = $true
      $global:FakeUpstream   = ''
      { & $script:ScriptPath -UpstreamUrl 'http://wsus.example.com' -Replica $true } | Should -Throw
      $global:FakeUpstream     | Should -Be ''
      $global:FakeSyncFromMU   | Should -BeTrue
    }
  }

}
