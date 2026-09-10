#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Specification for Invoke-WsusSynchronisation.ps1.

    .DESCRIPTION
        Runs anywhere, Linux CI included. The script's platform calls are Get-WsusServer,
        Start-Sleep and Get-Date, all cmdlets, so functions declared here stand in for them.

        TIME IS VIRTUAL, and that is not a convenience. The script's deadlines are wall-clock,
        correctly so; a Start-Sleep stub that simply returned would leave those deadlines arriving
        in real minutes while the loop spun hot. Get-Date reads a clock Start-Sleep advances, so the
        deadline tests exercise the comparison exactly as written and finish in microseconds.

        The stub models the server as something whose synchronisation and whose CONTENT are
        separate states, because that is the failure the script exists to prevent: a catalogue
        without its bytes is a server offering updates it cannot deliver, and a client with no
        route to Microsoft has nowhere else to look.

        GetLastSynchronizationInfo THROWS on a server that has never synchronised -- absence
        arrives as an exception rather than as a null -- and the stub reproduces that, because a
        script that let it escape would turn every first run into a failure.

        Stub state lives in $global: variables because inside a function called from a child
        SCRIPT, $script: resolves to the child's scope, not this file's.
#>

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-WsusSynchronisation.ps1'

  # A VIRTUAL CLOCK, and it is not a convenience. The script's deadlines are wall-clock -- correctly
  # so -- and a Start-Sleep stub that returns instantly would leave those deadlines arriving in real
  # minutes while the loop spun hot. Get-Date reads a time that Start-Sleep advances, so the
  # deadline tests exercise the real comparison and finish in microseconds.
  Function Get-Date {
    [CmdletBinding()]
    Param ()

    Return $global:FakeNow
  }

  Function Start-Sleep {
    [CmdletBinding()]
    Param ( [System.Int32]$Seconds )

    $global:FakeSleeps++
    $global:FakeNow = $global:FakeNow.AddSeconds($Seconds)

    # Each tick advances the modelled world: a running synchronisation finishes after the declared
    # number of polls, and outstanding content drains at the declared rate.
    If ($global:FakeSyncTicksLeft -gt 0) {
      $global:FakeSyncTicksLeft--
      If ($global:FakeSyncTicksLeft -le 0 -and -not $global:FakeSyncNeverStops) {
        $global:FakeStatus = 'NotProcessing'
      }
    }

    If ($global:FakeOutstanding -gt 0 -and -not $global:FakeContentStalls) {
      $global:FakeDownloaded = $global:FakeTotalBytes
      $global:FakeOutstanding = 0
    }
  }

  Function Get-WsusServer {
    [CmdletBinding()]
    Param ()

    If ($global:FakeServerNull) { Return $Null }

    $Server = [PSCustomObject]@{ Name = 'tcnaw-wsus01' }

    $Server | Add-Member -MemberType ScriptMethod -Name 'GetUpdateCount' -Value {
      Return $global:FakeUpdateCount
    }

    $Server | Add-Member -MemberType ScriptMethod -Name 'GetContentDownloadProgress' -Value {
      Return [PSCustomObject]@{
        TotalBytesToDownload = $global:FakeTotalBytes
        DownloadedBytes      = $global:FakeDownloaded
      }
    }

    $Server | Add-Member -MemberType ScriptMethod -Name 'GetSubscription' -Value {
      $Subscription = [PSCustomObject]@{}

      $Subscription | Add-Member -MemberType ScriptMethod -Name 'GetLastSynchronizationInfo' -Value {
        If ($global:FakeNeverSynced) {
          Throw 'The server has never synchronized.'
        }
        Return [PSCustomObject]@{ Result = $global:FakeLastResult }
      }

      $Subscription | Add-Member -MemberType ScriptMethod -Name 'GetSynchronizationStatus' -Value {
        Return $global:FakeStatus
      }

      $Subscription | Add-Member -MemberType ScriptMethod -Name 'StartSynchronization' -Value {
        $global:FakeStartCalls++
        $global:FakeOrder.Add('start')
        $global:FakeNeverSynced = $false
        $global:FakeStatus = 'Running'
        $global:FakeSyncTicksLeft = $global:FakeSyncTicks
      }

      $Subscription | Add-Member -MemberType ScriptMethod -Name 'StopSynchronization' -Value {
        $global:FakeStopCalls++
        $global:FakeOrder.Add('stop')
        $global:FakeStatus = 'NotProcessing'
      }

      Return $Subscription
    }

    Return $Server
  }

  $script:Arguments = @{
    ContentTimeoutSeconds = 600
    Force                 = $false
    TimeoutSeconds        = 600
  }

  $script:Invoke = { & $script:ScriptPath @script:Arguments }
  $script:InvokeForced = { & $script:ScriptPath @script:Arguments -Force $true }
  $script:InvokeWhatIf = { & $script:ScriptPath @script:Arguments -WhatIf }
}

Describe 'Invoke-WsusSynchronisation' {

  BeforeEach {
    $global:Ansible = [PSCustomObject]@{
      Changed   = $True
      CheckMode = $False
      Failed    = $False
      Result    = $Null
    }

    $global:FakeOrder = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeNow = [System.DateTime]::Parse('2026-09-10T00:00:00Z').ToUniversalTime()
    $global:FakeServerNull = $false
    $global:FakeNeverSynced = $true
    $global:FakeLastResult = 'Succeeded'
    $global:FakeStatus = 'NotProcessing'
    $global:FakeSyncTicks = 2
    $global:FakeSyncTicksLeft = 0
    $global:FakeSyncNeverStops = $false
    $global:FakeStartCalls = 0
    $global:FakeStopCalls = 0
    $global:FakeSleeps = 0
    $global:FakeUpdateCount = 12
    $global:FakeTotalBytes = 93342992
    $global:FakeDownloaded = 93342992
    $global:FakeOutstanding = 0
    $global:FakeContentStalls = $false
  }

  Context 'a server that has never spoken to its upstream' {

    # GetLastSynchronizationInfo throws rather than returning null on such a server. A script that
    # let that escape would turn every first run into a failure.
    It 'reads "never synchronised" out of the exception rather than failing on it' {
      $null = & $script:Invoke

      $global:FakeStartCalls | Should -Be 1
      $global:Ansible.Result.changed | Should -BeTrue
    }

    It 'waits for the synchronisation to reach a terminal state' {
      $null = & $script:Invoke

      $global:FakeSleeps | Should -BeGreaterThan 0
      $global:FakeStatus | Should -Be 'NotProcessing'
    }
  }

  Context 'a server that has already synchronised' {

    It 'fetches nothing when one already succeeded and no content is outstanding' {
      $global:FakeNeverSynced = $false

      $null = & $script:Invoke

      $global:FakeStartCalls | Should -Be 0
      $global:Ansible.Changed | Should -BeFalse
    }

    # Force is the upstream actor's own change report. A server pointed somewhere new holds a
    # catalogue from somewhere else, and "it synchronised once" stops being an answer about the
    # current source.
    It 'synchronises anyway when the upstream was just re-pointed' {
      $global:FakeNeverSynced = $false

      $null = & $script:InvokeForced

      $global:FakeStartCalls | Should -Be 1
    }

    # A previous run can time out waiting for content while the catalogue itself completed. That
    # server is converged in metadata and useless in practice.
    It 'waits for outstanding content even when the catalogue is already complete' {
      $global:FakeNeverSynced = $false
      $global:FakeDownloaded = 0
      $global:FakeOutstanding = $global:FakeTotalBytes

      $null = & $script:Invoke

      $global:FakeStartCalls | Should -Be 0
      $global:FakeDownloaded | Should -Be $global:FakeTotalBytes
    }
  }

  Context 'work already in flight' {

    # A synchronisation already running is not this one, and its result is not ours to read.
    It 'stops an in-flight synchronisation before starting its own' {
      $global:FakeStatus = 'Running'

      $null = & $script:Invoke

      $global:FakeStopCalls | Should -Be 1
      $global:FakeOrder.IndexOf('start') | Should -BeGreaterThan $global:FakeOrder.IndexOf('stop')
    }
  }

  Context 'what the server has to end up holding' {

    It 'refuses a synchronisation that never reaches a terminal state' {
      $global:FakeSyncNeverStops = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*did not finish within 600 seconds*'
    }

    # Terminal is not successful. A synchronisation that stops having failed leaves the server as
    # empty as one that never ran, and the difference is only visible here.
    It 'refuses a synchronisation that ends anything other than Succeeded' {
      $global:FakeLastResult = 'Failed'

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*ended Failed rather than Succeeded*'
    }

    # Metadata without content is a server offering updates it cannot deliver, to a client with no
    # route to Microsoft and nowhere else to look.
    It 'refuses when the content never finishes arriving' {
      $global:FakeDownloaded = 0
      $global:FakeOutstanding = $global:FakeTotalBytes
      $global:FakeContentStalls = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*still outstanding*'
    }

    It 'refuses a host where WSUS post-installation has not produced a server' {
      $global:FakeServerNull = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*post-installation must complete*'
    }

    It 'reports the change when the synchronisation started and the check then failed' {
      $global:FakeLastResult = 'Failed'

      { & $script:Invoke } | Should -Throw
      $global:Ansible.Changed | Should -BeTrue
    }
  }

  Context 'refusals and the transport contract' {

    It 'declares SupportsShouldProcess, which is what makes the module run it under --check' {
      $Command = Get-Command -Name $script:ScriptPath
      $Command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }

    It 'fetches nothing under -WhatIf' {
      $null = & $script:InvokeWhatIf

      $global:FakeStartCalls | Should -Be 0
      $global:FakeStopCalls | Should -Be 0
    }

    It 'still reports a change under -WhatIf, because the host needs one' {
      $null = & $script:InvokeWhatIf

      $global:Ansible.Result.changed | Should -BeTrue
    }
  }
}
