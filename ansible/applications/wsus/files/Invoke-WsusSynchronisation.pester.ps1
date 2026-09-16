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

    If ($global:FakeStopTicksLeft -gt 0) {
      $global:FakeStopTicksLeft--
      If ($global:FakeStopTicksLeft -le 0 -and -not $global:FakeStopNeverCompletes) {
        $global:FakeStatus = 'NotProcessing'
      }
    }

    If ($global:FakeNeedingFiles -gt 0 -and -not $global:FakeContentStalls) {
      $global:FakeNeedingFiles = 0
      $global:FakeDownloaded = $global:FakeTotalBytes
      # A server that reports its failures only as the queue drains -- the snapshot the wait exits
      # with, which a check placed before the sleep would never see.
      If ($global:FakeErrorsAppearOnPoll -gt 0) {
        $global:FakeServerErrors = $global:FakeErrorsAppearOnPoll
      }
    }
  }

  Function Get-WsusServer {
    [CmdletBinding()]
    Param ()

    If ($global:FakeServerNull) { Return $Null }

    $Server = [PSCustomObject]@{ Name = 'wsus01' }

    $Server | Add-Member -MemberType ScriptMethod -Name 'GetUpdateCount' -Value {
      Return $global:FakeUpdateCount
    }

    # UpdatesNeedingFilesCount is what says whether the server HAS its files.
    # GetContentDownloadProgress says only what is downloading right now, which reads zero on a
    # finished server, an unstarted one and a failed one alike. The script does not read it at all;
    # the member stays only so the fake's surface matches the real object it stands in for.
    $Server | Add-Member -MemberType ScriptMethod -Name 'GetStatus' -Value {
      Return [PSCustomObject]@{
        UpdatesNeedingFilesCount     = $global:FakeNeedingFiles
        UpdatesWithServerErrorsCount = $global:FakeServerErrors
      }
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
        If ($global:FakeSyncInfoFaults) {
          Throw 'The database is unavailable.'
        }
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

      # ASYNCHRONOUS, as it is on a real server: the status passes through Stopping on its way to
      # NotProcessing, and StartSynchronization throws for as long as it sits there. A stub that
      # stopped instantly would let a script race straight past the state that breaks it.
      $Subscription | Add-Member -MemberType ScriptMethod -Name 'StopSynchronization' -Value {
        $global:FakeStopCalls++
        $global:FakeOrder.Add('stop')
        $global:FakeStatus = 'Stopping'
        $global:FakeStopTicksLeft = $global:FakeStopTicks
      }

      $Subscription | Add-Member -MemberType ScriptMethod -Name 'GetSynchronizationHistory' -Value {
        If ($global:FakeNeverSynced) { Return @() }
        Return @([PSCustomObject]@{ Id = 1 })
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
  $script:InvokeStart = { & $script:ScriptPath @script:Arguments -Mode 'start' }
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
    $global:FakeTotalBytes = 69881768
    $global:FakeDownloaded = 69881768
    $global:FakeNeedingFiles = 0
    $global:FakeServerErrors = 0
    $global:FakeErrorsAppearOnPoll = 0
    $global:FakeContentStalls = $false
    $global:FakeStopTicks = 2
    $global:FakeStopTicksLeft = 0
    $global:FakeStopNeverCompletes = $false
    $global:FakeSyncInfoFaults = $false
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
      $global:FakeNeedingFiles = 3

      $null = & $script:Invoke

      $global:FakeStartCalls | Should -Be 0
      $global:FakeNeedingFiles | Should -Be 0
    }

    # The byte counters describe what is downloading NOW, so they read zero on a finished server,
    # an unstarted one and a failed one alike. A script that waited on them would return instantly
    # from an empty queue and report a catalogue whose files never arrived.
    It 'waits on files still needed even when no bytes are moving' {
      $global:FakeNeverSynced = $false
      $global:FakeNeedingFiles = 5
      $global:FakeDownloaded = $global:FakeTotalBytes

      $null = & $script:Invoke

      $global:FakeNeedingFiles | Should -Be 0
      $global:Ansible.Result.needing_files | Should -Be 0
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

    # Stop is asynchronous. The server sits in Stopping on its way to NotProcessing and
    # StartSynchronization throws for as long as it is there, so asking it to stop and starting in
    # the next statement is a race a busy server wins.
    It 'waits for the stop to finish before starting, rather than racing it' {
      $global:FakeStatus = 'Running'

      $null = & $script:Invoke

      $global:FakeStatus | Should -Not -Be 'Stopping'
      $global:FakeStartCalls | Should -Be 1
    }

    It 'refuses to start underneath a synchronisation that will not stop' {
      $global:FakeStatus = 'Running'
      $global:FakeStopNeverCompletes = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*had not within 600 seconds*'
      $global:FakeStartCalls | Should -Be 0
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
      $global:FakeNeedingFiles = 4
      $global:FakeContentStalls = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*still need files*'
    }

    # A download that will never succeed leaves the count above zero forever, and waiting the full
    # deadline for it is a slow way to learn something the server already knows.
    It 'refuses immediately when the server reports content it cannot download' {
      $global:FakeNeedingFiles = 4
      $global:FakeServerErrors = 2
      $global:FakeContentStalls = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*cannot download*'
    }

    # The two counts are INDEPENDENT. An update in Failed or LicenseAgreementFailed state is an
    # error that is not outstanding work, so a server can report errors while needing no files --
    # and a check that lived only inside the wait loop would never run, because the loop is entered
    # only when files ARE outstanding.
    It 'refuses errors the server reports even when nothing is outstanding' {
      $global:FakeNeverSynced = $false
      $global:FakeNeedingFiles = 0
      $global:FakeServerErrors = 3

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*cannot download*'
    }

    # And on the snapshot the wait exits with, which is the other way past a check that only ran
    # before the sleep.
    It 'refuses errors that appear on the last poll of the wait' {
      $global:FakeNeedingFiles = 2
      $global:FakeErrorsAppearOnPoll = 5

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*cannot download*'
    }

    # A server with no history and a server that could not answer both raise here, and they mean
    # opposite things. Starting a synchronisation to paper over a database fault would hide the
    # fault and report a change.
    It 'rethrows a fault rather than reading it as never synchronised' {
      $global:FakeNeverSynced = $false
      $global:FakeSyncInfoFaults = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*database is unavailable*'
      $global:FakeStartCalls | Should -Be 0
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

  Context 'Mode start begins a synchronisation and does not wait for it' {

    It 'starts exactly one synchronisation, as wait mode does' {
      $null = & $script:InvokeStart
      $global:FakeStartCalls | Should -Be 1
    }

    It 'reports the host changed, because a started synchronisation is already writing' {
      $null = & $script:InvokeStart
      $global:Ansible.Result.changed | Should -BeTrue
    }

    It 'says plainly that it did not wait' {
      $null = & $script:InvokeStart
      $global:Ansible.Result.mode   | Should -Be 'start'
      $global:Ansible.Result.waited | Should -BeFalse
      $global:Ansible.Result.msg    | Should -BeLike '*not waited for*'
    }

    It 'reports counts as -1 rather than 0, because it measured nothing' {
      $null = & $script:InvokeStart
      $global:Ansible.Result.update_count  | Should -Be -1
      $global:Ansible.Result.needing_files | Should -Be -1
      $global:Ansible.Result.result        | Should -Be 'NotWaited'
    }

    It 'returns the same key set as wait mode, so a reader never has to guess which ran' {
      $null = & $script:InvokeStart
      $startKeys = ($global:Ansible.Result.Keys | Sort-Object) -join ','
      $null = & $script:Invoke
      $waitKeys = ($global:Ansible.Result.PSObject.Properties.Name | Sort-Object) -join ','
      $startKeys | Should -Be $waitKeys
    }

    It 'wait mode still waits, and still reports what it measured' {
      $null = & $script:Invoke
      $global:Ansible.Result.mode   | Should -Be 'wait'
      $global:Ansible.Result.waited | Should -BeTrue
    }

    It 'on a server that already synchronised, reports start mode with nothing started or waited' {
      $global:FakeNeverSynced = $false
      $global:FakeLastResult = 'Succeeded'
      $null = & $script:InvokeStart
      $global:FakeStartCalls        | Should -Be 0
      $global:Ansible.Result.mode   | Should -Be 'start'
      $global:Ansible.Result.started | Should -BeFalse
      $global:Ansible.Result.waited  | Should -BeFalse
      $global:Ansible.Result.changed | Should -BeFalse
    }

    It 'refuses a mode it does not implement' {
      { & $script:ScriptPath @script:Arguments -Mode 'disabled' } | Should -Throw
    }
  }

}
