#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Invoke-SusdbAdoption.ps1 (org pair convention: every script ships with a
    sibling <Name>.pester.ps1; the pester-matrix workflow runs one leg per pair).

    Runs anywhere, Linux CI included. The script's only platform call is New-Object against
    System.Data.SqlClient, which this file stubs around in-memory state, so the whole decision
    surface -- attach, skip, the health gate, and the rollback boundary -- is exercised with no
    SQL Server present.

    Every statement the script sends is recorded in $global:FakeSql. That is the point of the
    stub: this script's job is to issue exactly one mutation and to undo exactly that one, so the
    spec asserts on the statements themselves rather than on a return value that could be right
    for the wrong reason.

    Stub state lives in $global: variables because inside a function called from a child SCRIPT,
    $script: resolves to the child script's own scope, not this file's.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-SusdbAdoption.ps1'
  $script:DataFile = 'E:\MSSQL\Data\SUSDB.mdf'
  $script:LogFile = 'E:\MSSQL\Log\SUSDB_log.ldf'

  $script:Invoke = {
    & $script:ScriptPath -DataFile $script:DataFile -LogFile $script:LogFile
  }

  # The transport does not just set $Ansible.CheckMode: because this script declares
  # SupportsShouldProcess, win_powershell also passes -WhatIf. Only this invoker reproduces the
  # second half.
  $script:InvokeWhatIf = {
    & $script:ScriptPath -DataFile $script:DataFile -LogFile $script:LogFile -WhatIf
  }

  Function New-Object {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$TypeName, [Parameter()] [System.Object]$ArgumentList)

    If ($TypeName -notlike '*SqlConnection') { Throw ('Unexpected type: {0}' -f $TypeName) }
    $global:FakeConnectionString = [System.String]$ArgumentList

    $Connection = [PSCustomObject]@{}
    $Connection | Add-Member -MemberType ScriptMethod -Name 'Open' -Value { $global:FakeOpens++ }
    $Connection | Add-Member -MemberType ScriptMethod -Name 'Close' -Value { $global:FakeCloses++ }
    $Connection | Add-Member -MemberType ScriptMethod -Name 'CreateCommand' -Value {
      $Command = [PSCustomObject]@{ CommandText = '' }

      $Command | Add-Member -MemberType ScriptMethod -Name 'ExecuteScalar' -Value {
        $global:FakeSql += $this.CommandText
        If ($global:FakeStateReadThrows -and $this.CommandText -match 'state_desc') {
          Throw 'connection reset while reading state'
        }
        If ($this.CommandText -match 'FROM sys\.databases WHERE name') {
          If ($this.CommandText -match 'state_desc') { Return $global:FakeState }
          Return $(If ($global:FakeAttached) { 1 } Else { 0 })
        }
        Throw ('Unexpected scalar query: {0}' -f $this.CommandText)
      }

      $Command | Add-Member -MemberType ScriptMethod -Name 'ExecuteNonQuery' -Value {
        $global:FakeSql += $this.CommandText
        If ($this.CommandText -match 'FOR ATTACH') { $global:FakeAttached = $true }
        If ($this.CommandText -match 'sp_detach_db') { $global:FakeAttached = $false }
        Return 0
      }

      Return $Command
    }
    Return $Connection
  }

}

Describe 'Invoke-SusdbAdoption' {

  BeforeEach {
    $global:FakeAttached = $false
    $global:FakeState = 'ONLINE'
    $global:FakeStateReadThrows = $false
    $global:FakeSql = @()
    $global:FakeOpens = 0
    $global:FakeCloses = 0
    $global:FakeConnectionString = ''
    $global:Ansible = [PSCustomObject]@{ Changed = $true; CheckMode = $false; Result = $null }
  }

  AfterEach {
    foreach ($name in @(
        'FakeAttached', 'FakeState', 'FakeStateReadThrows',
        'FakeSql', 'FakeOpens', 'FakeCloses', 'FakeConnectionString', 'Ansible'
      )) {
      Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
    }
  }

  Context 'a preserved database the engine does not have' {

    It 'attaches it and reports the change' {
      $null = & $script:Invoke

      $global:Ansible.Result.adopted | Should -BeTrue
      $global:Ansible.Result.changed | Should -BeTrue
      $global:Ansible.Result.attached_before | Should -BeFalse
      $global:Ansible.Changed | Should -BeTrue
    }

    # The paths are the whole instruction. An attach naming anything else would succeed and serve
    # from storage this deployment never placed.
    It 'names both declared files in the attach, and attaches nothing else' {
      $null = & $script:Invoke

      $attach = @($global:FakeSql | Where-Object { $_ -match 'FOR ATTACH' })
      $attach.Count | Should -Be 1
      # Ordered, not merely present. Both paths appearing somewhere in the statement is satisfied
      # just as well by swapping them between the ON and LOG ON clauses, which would attach the
      # log as the data file.
      $attach[0] | Should -Match ([regex]::Escape("ON (FILENAME = N'E:\MSSQL\Data\SUSDB.mdf')"))
      $attach[0] | Should -Match ([regex]::Escape("LOG ON (FILENAME = N'E:\MSSQL\Log\SUSDB_log.ldf')"))
    }

    # ATTACH_REBUILD_LOG would invent a log for a pair the caller classified as complete, turning
    # a wrong classification into silent data surgery.
    It 'never rebuilds a log' {
      $null = & $script:Invoke

      ($global:FakeSql -join ' ') | Should -Not -BeLike '*ATTACH_REBUILD_LOG*'
    }

    It 'closes the connection it opened' {
      $null = & $script:Invoke

      $global:FakeOpens | Should -Be 1
      $global:FakeCloses | Should -Be 1
    }
  }

  Context 'a database the engine already has' {

    It 'does nothing and reports no change' {
      $global:FakeAttached = $true

      $null = & $script:Invoke

      $global:Ansible.Result.adopted | Should -BeFalse
      $global:Ansible.Result.changed | Should -BeFalse
      $global:Ansible.Result.attached_before | Should -BeTrue
      $global:Ansible.Changed | Should -BeFalse
    }

    It 'issues no attach at all' {
      $global:FakeAttached = $true

      $null = & $script:Invoke

      ($global:FakeSql -join ' ') | Should -Not -BeLike '*FOR ATTACH*'
    }
  }

  Context 'the health gate' {

    It 'refuses a database that is not ONLINE' {
      $global:FakeState = 'RECOVERY_PENDING'

      { & $script:Invoke } | Should -Throw '*RECOVERY_PENDING*'
    }

  }

  Context 'the rollback boundary' {

    # What this invocation attached, it detaches. Nothing else.
    It 'detaches a database it attached when a gate fails' {
      $global:FakeState = 'SUSPECT'

      { & $script:Invoke } | Should -Throw

      ($global:FakeSql -join ' ') | Should -BeLike '*sp_detach_db*'
      $global:FakeAttached | Should -BeFalse
    }

    # The hole: a failure while READING the state is as much a reason to roll back as a failed
    # state. Before this, the read threw straight past the rollback and left the database attached.
    It 'detaches what it attached when the state read itself fails' {
      $global:FakeStateReadThrows = $true

      { & $script:Invoke } | Should -Throw

      ($global:FakeSql -join ' ') | Should -BeLike '*sp_detach_db*'
      $global:FakeAttached | Should -BeFalse
    }

    # sp_detach_db's documented limitations require emergency mode for a SUSPECT database, and
    # SUSPECT is one of the two states the gate above exists to catch.
    It 'takes the database through emergency and single-user to detach it' {
      $global:FakeState = 'SUSPECT'

      { & $script:Invoke } | Should -Throw

      $detach = @($global:FakeSql | Where-Object { $_ -match 'sp_detach_db' })
      # ORDERED, not merely present: EMERGENCY must precede SINGLE_USER and both must precede the
      # detach, because the engine refuses to detach a SUSPECT database that is not in emergency
      # mode -- and SUSPECT is one of the two states the gate above exists to catch. Asserting
      # presence alone passes just as well when the detach runs first.
      $detach[0] | Should -Match 'SET EMERGENCY;[\s\S]*SET SINGLE_USER WITH ROLLBACK IMMEDIATE;[\s\S]*sp_detach_db'
      # skipchecks, so the rollback does not run UPDATE STATISTICS over a database it is
      # discarding, and the procedure's own status is raised rather than discarded.
      $detach[0] | Should -BeLike "*@skipchecks = 'true'*"
      $detach[0] | Should -BeLike '*THROW 50000*'
      $detach[0] | Should -Not -BeLike '*SET OFFLINE*'
    }

    # A database that was already there is not this script's to remove, however unhealthy.
    It 'leaves a pre-existing database attached when a gate fails' {
      $global:FakeAttached = $true
      $global:FakeState = 'SUSPECT'

      { & $script:Invoke } | Should -Throw

      ($global:FakeSql -join ' ') | Should -Not -BeLike '*sp_detach_db*'
      $global:FakeAttached | Should -BeTrue
    }
  }

  Context 'the transport contract' {

    It 'talks to the local default instance, the one the role configures' {
      $null = & $script:Invoke

      $global:FakeConnectionString | Should -Match '(^|;)\s*Server=\.\s*;'
    }

    It 'declares SupportsShouldProcess, which is what makes the module run it under --check' {
      $Source = Get-Content -LiteralPath $script:ScriptPath -Raw

      $Source | Should -Match '\[CmdletBinding\(SupportsShouldProcess\)\]'
    }

    # win_powershell passes -WhatIf alongside CheckMode. Under it the script must not attach.
    It 'attaches nothing under -WhatIf' {
      $null = & $script:InvokeWhatIf

      ($global:FakeSql -join ' ') | Should -Not -BeLike '*FOR ATTACH*'
      $global:Ansible.Result.adopted | Should -BeFalse
    }

    # ...but it must still say the host needs adopting. Reporting the deed under --check would
    # tell an operator that a host which cannot converge needs nothing done to it.
    It 'still reports a change under -WhatIf, because the host needs one' {
      $null = & $script:InvokeWhatIf

      $global:Ansible.Result.changed | Should -BeTrue
      $global:Ansible.Changed | Should -BeTrue
      $global:Ansible.Result.msg | Should -BeLike '*would be attached*'
    }

    # The transport seeds Changed true. A throw must not leave it that way and report a change the
    # rollback already undid.
    It 'reports no change when it throws' {
      $global:FakeState = 'SUSPECT'

      { & $script:Invoke } | Should -Throw

      $global:Ansible.Changed | Should -BeFalse
    }

  }
}
