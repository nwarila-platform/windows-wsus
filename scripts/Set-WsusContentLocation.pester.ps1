#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Specification for Set-WsusContentLocation.ps1.

    .DESCRIPTION
        Runs anywhere, Linux CI included. Every platform call the script makes is a cmdlet --
        Get-ItemPropertyValue, Get-WsusServer, Get-Item, Import-Module and Start-Process -- which
        is why the move goes through Start-Process rather than the call operator: a function
        declared here can stand in for a cmdlet and cannot stand in for `& $path`.

        The stub models the move as state. Start-Process rewrites the three recorded paths the way
        wsusutil does, so a test can distinguish a script that moved from one that only reported,
        and $global:FakeMoveExitCode / $global:FakeMovePartial let a test model a command that
        fails, or one that succeeds and leaves the records disagreeing.

        Stub state lives in $global: variables because inside a function called from a child
        SCRIPT, $script: resolves to the child's scope, not this file's.
#>

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-WsusContentLocation.ps1'
  $script:Root = 'F:\WSUS'
  $script:Cache = 'F:\WSUS\WsusContent'

  Function Import-Module {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$Name)
  }

  Function Get-ItemPropertyValue {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$Path, [Parameter()] [System.String]$Name)

    Return $global:FakeRegistry
  }

  Function Get-WsusServer {
    [CmdletBinding()]
    Param ()

    If ($global:FakeApiThrows) { Throw 'The WSUS administration console is not installed.' }
    If ($global:FakeApiNull) { Return $Null }

    $Server = [PSCustomObject]@{}
    $Server | Add-Member -MemberType ScriptMethod -Name 'GetConfiguration' -Value {
      Return [PSCustomObject]@{ LocalContentCachePath = $global:FakeApi }
    }
    Return $Server
  }

  Function Get-Item {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$Path)

    Return [PSCustomObject]@{ PhysicalPath = $global:FakeIis }
  }

  Function Start-Process {
    [CmdletBinding()]
    Param (
      [Parameter()] [System.String]$FilePath,
      [Parameter()] [System.Object]$ArgumentList,
      [Parameter()] [System.Management.Automation.SwitchParameter]$NoNewWindow,
      [Parameter()] [System.Management.Automation.SwitchParameter]$PassThru,
      [Parameter()] [System.Management.Automation.SwitchParameter]$Wait
    )

    $global:FakeMoveCalls++
    $global:FakeMoveArgs = @($ArgumentList)

    If ($global:FakeMoveExitCode -eq 0) {
      $Target = [System.String]@($ArgumentList)[1]
      $global:FakeRegistry = $Target
      $global:FakeApi = '{0}\WsusContent' -f $Target
      # wsusutil repoints IIS too, and really does leave a trailing separator there.
      If (-not $global:FakeMovePartial) { $global:FakeIis = '{0}\WsusContent\' -f $Target }
    }
    Return [PSCustomObject]@{ ExitCode = $global:FakeMoveExitCode }
  }

  $script:Invoke = {
    & $script:ScriptPath -ContentRoot $script:Root `
      -WsusUtilPath 'C:\Program Files\Update Services\Tools\wsusutil.exe' `
      -MoveLogPath 'C:\Windows\Temp\wsus-movecontent.log'
  }
  $script:InvokeWhatIf = {
    & $script:ScriptPath -ContentRoot $script:Root `
      -WsusUtilPath 'C:\Program Files\Update Services\Tools\wsusutil.exe' `
      -MoveLogPath 'C:\Windows\Temp\wsus-movecontent.log' -WhatIf
  }
}

Describe 'Set-WsusContentLocation' {

  BeforeEach {
    $global:FakeRegistry = 'F:\WSUS'
    $global:FakeApi = 'F:\WSUS\WsusContent'
    $global:FakeIis = 'F:\WSUS\WsusContent\'
    $global:FakeApiThrows = $false
    $global:FakeApiNull = $false
    $global:FakeMoveCalls = 0
    $global:FakeMoveArgs = @()
    $global:FakeMoveExitCode = 0
    $global:FakeMovePartial = $false
    $global:Ansible = [PSCustomObject]@{ Changed = $true; CheckMode = $false; Result = $null }
  }

  Context 'when the content is already where it belongs' {

    # Measured on a converged host: IIS answers with a trailing separator where the API does not.
    # Comparing raw would move a populated store on every converge.
    It 'moves nothing, and does not mistake the IIS trailing separator for drift' {
      $null = & $script:Invoke

      $global:FakeMoveCalls | Should -Be 0
      $global:Ansible.Changed | Should -BeFalse
      $global:Ansible.Result.iis_path | Should -Be $script:Cache
    }

    It 'folds forward slashes, so a value in the other shape is not drift either' {
      $global:FakeRegistry = 'F:/WSUS/'

      $null = & $script:Invoke

      $global:FakeMoveCalls | Should -Be 0
    }
  }

  Context 'when the store is somewhere else' {

    It 'moves it to the declared root and reports the change' {
      $global:FakeRegistry = 'C:\WSUS'
      $global:FakeApi = 'C:\WSUS\WsusContent'
      $global:FakeIis = 'C:\WSUS\WsusContent\'

      $null = & $script:Invoke

      $global:FakeMoveCalls | Should -Be 1
      $global:Ansible.Changed | Should -BeTrue
      $global:Ansible.Result.api_path | Should -Be $script:Cache
    }

    # -skipcopy would switch the pointers without moving the bytes, leaving a server that reports
    # health and serves nothing.
    It 'copies rather than skipping the copy' {
      $global:FakeApi = 'C:\WSUS\WsusContent'

      $null = & $script:Invoke

      @($global:FakeMoveArgs)[0] | Should -Be 'movecontent'
      @($global:FakeMoveArgs) | Should -Not -Contain '-skipcopy'
    }

    It 'fails when wsusutil reports a non-zero exit code' {
      $global:FakeApi = 'C:\WSUS\WsusContent'
      $global:FakeMoveExitCode = 1

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*movecontent exited 1*'
    }

    # An exit code of zero says the command ran, not that the three records agree.
    It 'fails when the move succeeds but IIS still serves the old path' {
      $global:FakeRegistry = 'C:\WSUS'
      $global:FakeApi = 'C:\WSUS\WsusContent'
      $global:FakeIis = 'C:\WSUS\WsusContent\'
      $global:FakeMovePartial = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*does not keep its content where declared*'
    }

    It 'still reports the change when the move ran and the check then failed' {
      $global:FakeRegistry = 'C:\WSUS'
      $global:FakeApi = 'C:\WSUS\WsusContent'
      $global:FakeIis = 'C:\WSUS\WsusContent\'
      $global:FakeMovePartial = $true

      { & $script:Invoke } | Should -Throw

      $global:Ansible.Changed | Should -BeTrue
    }
  }

  Context 'what it refuses' {

    # Editing the registry directly is unsupported and movecontent will not reconcile this, so
    # guessing would be worse than stopping.
    It 'refuses a registry and API that were edited apart' {
      $global:FakeRegistry = 'C:\WSUS'

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*records its content inconsistently*'
      $global:FakeMoveCalls | Should -Be 0
    }

    # An unreadable API used to come back as an empty string, which compares as "wrong place" --
    # so a stopped WSUS service would have started a full copy of a populated store, and satisfied
    # the split-brain clause at the same time. The realistic path is a host back from a reboot.
    It 'refuses an unreadable API rather than reading it as the wrong location' {
      $global:FakeApiThrows = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*will not say where its content lives*'
      $global:FakeMoveCalls | Should -Be 0
    }

    It 'refuses a server that answers with nothing at all' {
      $global:FakeApiNull = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*will not say where its content lives*'
      $global:FakeMoveCalls | Should -Be 0
    }
  }

  Context 'the transport contract' {

    It 'declares SupportsShouldProcess, which is what makes the module run it under --check' {
      (Get-Command -Name $script:ScriptPath).Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }

    It 'moves nothing under -WhatIf' {
      $global:FakeApi = 'C:\WSUS\WsusContent'

      $null = & $script:InvokeWhatIf

      $global:FakeMoveCalls | Should -Be 0
    }

    # Suppression arrives as an injected -WhatIf, so the run's own Changed flag stays false on a
    # host that plainly needs the move. Reporting that would tell a --check run the host was
    # already where it should be, which is the one question --check exists to answer.
    It 'still reports the change under -WhatIf, because the host needs one' {
      $global:FakeApi = 'C:\WSUS\WsusContent'

      $null = & $script:InvokeWhatIf

      $global:Ansible.Result.changed | Should -BeTrue
    }

    It 'reports no change under -WhatIf when the content is already where it was declared' {
      $null = & $script:InvokeWhatIf

      $global:Ansible.Result.changed | Should -BeFalse
    }
  }
}
