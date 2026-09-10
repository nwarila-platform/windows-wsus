#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Specification for Set-WsusHttpsListener.ps1.

    .DESCRIPTION
        Runs anywhere, Linux CI included. Every platform call the script makes is a cmdlet -- the
        Cert: and IIS: providers are reached through Get-Item/New-Item/Remove-Item, IIS
        configuration through Get-WebConfiguration/Set-WebConfigurationProperty, the registry
        through Get-ItemProperty, and wsusutil through Start-Process -- so a function declared here
        stands in for each. A call operator would not have been shadowable; that is why the script
        runs wsusutil through Start-Process.

        The stubs model the host as three INDEPENDENT pieces of state, because that is the failure
        the script exists to prevent: a server whose listener holds a certificate, whose
        directories still accept plain HTTP, and which still tells its clients an http:// URL reads
        as configured from any one of the three and serves nobody. FakeBindingDrops, FakeFlagDrops
        and FakeWsusUtilNoOp each model one piece accepting a write and keeping nothing.

        Get-ItemProperty deliberately omits ServerCertificateName until wsusutil has run, because
        that is what the real key does -- and a script that dereferenced it directly under
        StrictMode would fail with an error about the property rather than an answer about the
        server.

        Stub state lives in $global: variables because inside a function called from a child
        SCRIPT, $script: resolves to the child's scope, not this file's.
#>

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-WsusHttpsListener.ps1'
  $script:Pinned = '8760E9DA2B79D7FCFB5C8DADD72628649029B348'
  $script:Dns = 'tcnaw-wsus01.tcn.trinitytechnicalservices.com'
  $script:Site = 'WSUS Administration'
  $script:Vdirs = @(
    'ApiRemoting30'
    'ClientWebService'
    'DssAuthWebService'
    'ServerSyncWebService'
    'SimpleAuthWebService'
  )

  Function Get-Item {
    [CmdletBinding()]
    Param ( [System.String]$Path )

    $global:FakeOrder.Add('get-item')

    If ($Path -like 'Cert:*') {
      If ($global:FakeCertMissing) { Return $Null }
      Return [PSCustomObject]@{
        Thumbprint    = $global:FakeCertThumbprint
        HasPrivateKey = $global:FakeCertHasKey
        NotAfter      = $global:FakeCertNotAfter
      }
    }

    If ($Path -like 'IIS:\SslBindings*') {
      If ([System.String]::IsNullOrEmpty($global:FakeBoundThumbprint)) { Return $Null }
      Return [PSCustomObject]@{ Thumbprint = $global:FakeBoundThumbprint }
    }

    Throw ('The script asked for an unexpected path: {0}' -f $Path)
  }

  Function New-Item {
    [CmdletBinding()]
    Param ( [System.String]$Path, [System.Object]$Value )

    $global:FakeOrder.Add('bind')
    $global:FakeBindCalls++
    If (-not $global:FakeBindingDrops) { $global:FakeBoundThumbprint = $Value.Thumbprint }
  }

  Function Remove-Item {
    [CmdletBinding()]
    Param ( [System.String]$Path, [Switch]$Force )

    $global:FakeOrder.Add('unbind')
    $global:FakeUnbindCalls++
    $global:FakeBoundThumbprint = ''
  }

  Function Get-WebConfiguration {
    [CmdletBinding()]
    Param ( [System.String]$Filter, [System.String]$PSPath, [System.String]$Location )

    Return [PSCustomObject]@{ sslFlags = [System.String]$global:FakeSslFlags[$Location] }
  }

  Function Set-WebConfigurationProperty {
    [CmdletBinding()]
    Param (
      [System.String]$Filter,
      [System.String]$Name,
      [System.String]$PSPath,
      [System.String]$Location,
      [System.Object]$Value
    )

    $global:FakeOrder.Add('secure')
    $global:FakeSecureCalls++
    If (-not $global:FakeFlagDrops) { $global:FakeSslFlags[$Location] = [System.String]$Value }
  }

  Function Get-ItemProperty {
    [CmdletBinding()]
    Param ( [System.String]$Path )

    If ($global:FakeSetupMissing) { Return $Null }

    $Setup = [PSCustomObject]@{ UsingSSL = $global:FakeUsingSsl }
    If ($Null -ne $global:FakeRecordedName) {
      $Setup | Add-Member -NotePropertyName:'ServerCertificateName' -NotePropertyValue:$global:FakeRecordedName
    }
    Return $Setup
  }

  Function Start-Process {
    [CmdletBinding()]
    Param (
      [System.String]$FilePath,
      [System.String[]]$ArgumentList,
      [Switch]$Wait,
      [Switch]$NoNewWindow,
      [Switch]$PassThru
    )

    $global:FakeOrder.Add('wsusutil')
    $global:FakeWsusUtilCalls++
    $global:FakeWsusUtilArgs = $ArgumentList

    If ($global:FakeWsusUtilExit -eq 0 -and -not $global:FakeWsusUtilNoOp) {
      $global:FakeUsingSsl = 1
      $global:FakeRecordedName = $ArgumentList[1]
    }

    Return [PSCustomObject]@{ ExitCode = $global:FakeWsusUtilExit }
  }

  $script:Arguments = @{
    DnsName      = $script:Dns
    Port         = 8531
    SecuredPath  = $script:Vdirs
    SiteName     = $script:Site
    Thumbprint   = $script:Pinned
    WsusUtilPath = 'C:\Program Files\Update Services\Tools\wsusutil.exe'
  }

  $script:Invoke = { & $script:ScriptPath @script:Arguments }
  $script:InvokeWhatIf = { & $script:ScriptPath @script:Arguments -WhatIf }

  # Puts the stub host in the state a fully converged server is in, so a test that wants one piece
  # of drift declares only that piece.
  $script:Converge = {
    $global:FakeBoundThumbprint = $script:Pinned
    $global:FakeUsingSsl = 1
    $global:FakeRecordedName = $script:Dns
    ForEach ($Vdir in $script:Vdirs) {
      $global:FakeSslFlags[('{0}/{1}' -f $script:Site, $Vdir)] = 'Ssl'
    }
  }
}

Describe 'Set-WsusHttpsListener' {

  BeforeEach {
    $global:Ansible = [PSCustomObject]@{
      Changed   = $True
      CheckMode = $False
      Failed    = $False
      Result    = $Null
    }

    $global:FakeOrder = [System.Collections.Generic.List[System.String]]::new()
    $global:FakeSslFlags = @{}

    $global:FakeCertMissing = $false
    $global:FakeCertThumbprint = $script:Pinned
    $global:FakeCertHasKey = $true
    $global:FakeCertNotAfter = (Get-Date).AddYears(1)

    $global:FakeBoundThumbprint = ''
    $global:FakeBindingDrops = $false
    $global:FakeFlagDrops = $false

    $global:FakeSetupMissing = $false
    $global:FakeUsingSsl = 0
    $global:FakeRecordedName = $null

    $global:FakeWsusUtilExit = 0
    $global:FakeWsusUtilNoOp = $false
    $global:FakeWsusUtilArgs = @()

    $global:FakeBindCalls = 0
    $global:FakeUnbindCalls = 0
    $global:FakeSecureCalls = 0
    $global:FakeWsusUtilCalls = 0
  }

  Context 'a server that has never served HTTPS' {

    It 'attaches the pinned certificate to the listener' {
      $null = & $script:Invoke

      $global:FakeBindCalls | Should -Be 1
      $global:FakeBoundThumbprint | Should -Be $script:Pinned
    }

    It 'requires SSL on every directory it was given' {
      $null = & $script:Invoke

      $global:FakeSecureCalls | Should -Be $script:Vdirs.Count
      ForEach ($Vdir in $script:Vdirs) {
        $global:FakeSslFlags[('{0}/{1}' -f $script:Site, $Vdir)] | Should -Be 'Ssl'
      }
    }

    It 'tells WSUS its own name, passing the name it was given' {
      $null = & $script:Invoke

      $global:FakeWsusUtilCalls | Should -Be 1
      $global:FakeWsusUtilArgs[0] | Should -Be 'configuressl'
      $global:FakeWsusUtilArgs[1] | Should -Be $script:Dns
    }

    # wsusutil validates the SSL configuration it records, so it cannot run before there is one.
    It 'runs wsusutil only after the listener and the directories are done' {
      $null = & $script:Invoke

      $global:FakeOrder.IndexOf('wsusutil') | Should -BeGreaterThan $global:FakeOrder.IndexOf('bind')
      $global:FakeOrder.IndexOf('wsusutil') | Should -BeGreaterThan $global:FakeOrder.LastIndexOf('secure')
    }

    It 'reports the change' {
      $null = & $script:Invoke

      $global:Ansible.Changed | Should -BeTrue
      $global:Ansible.Result.changed | Should -BeTrue
    }
  }

  Context 'a server that already serves HTTPS' {

    It 'writes nothing when all three are already true' {
      & $script:Converge

      $null = & $script:Invoke

      $global:FakeBindCalls | Should -Be 0
      $global:FakeSecureCalls | Should -Be 0
      $global:FakeWsusUtilCalls | Should -Be 0
      $global:Ansible.Changed | Should -BeFalse
    }

    # sslFlags is a flag list. A site carrying Ssl128 as well requires SSL exactly as much, and a
    # whole-string compare would rewrite it on every converge.
    It 'treats a flag list containing Ssl as already requiring SSL' {
      & $script:Converge
      ForEach ($Vdir in $script:Vdirs) {
        $global:FakeSslFlags[('{0}/{1}' -f $script:Site, $Vdir)] = 'Ssl,Ssl128'
      }

      $null = & $script:Invoke

      $global:FakeSecureCalls | Should -Be 0
    }

    It 'does not treat Ssl128 alone as requiring SSL' {
      & $script:Converge
      $global:FakeSslFlags[('{0}/{1}' -f $script:Site, 'ClientWebService')] = 'Ssl128'

      $null = & $script:Invoke

      $global:FakeSecureCalls | Should -Be 1
    }
  }

  Context 'a server that is part of the way there' {

    It 'replaces a listener presenting a different certificate' {
      & $script:Converge
      $global:FakeBoundThumbprint = '0000000000000000000000000000000000000000'

      $null = & $script:Invoke

      $global:FakeUnbindCalls | Should -Be 1
      $global:FakeBindCalls | Should -Be 1
      $global:FakeBoundThumbprint | Should -Be $script:Pinned
      $global:Ansible.Result.changed | Should -BeTrue
    }

    It 'secures only the directories that are not secured' {
      & $script:Converge
      $global:FakeSslFlags[('{0}/{1}' -f $script:Site, 'ClientWebService')] = ''

      $null = & $script:Invoke

      $global:FakeSecureCalls | Should -Be 1
      $global:FakeBindCalls | Should -Be 0
      $global:Ansible.Result.changed | Should -BeTrue
    }

    # The recorded name is what WSUS hands its clients. A stale one sends them to a name the
    # certificate is not valid for, on a server that reports itself as using SSL.
    It 'runs wsusutil when SSL is on but the recorded name is stale' {
      & $script:Converge
      $global:FakeRecordedName = 'some-other-host.example.com'

      $null = & $script:Invoke

      $global:FakeWsusUtilCalls | Should -Be 1
      $global:FakeRecordedName | Should -Be $script:Dns
      $global:Ansible.Result.changed | Should -BeTrue
    }

    It 'runs wsusutil when the name matches but SSL is off' {
      & $script:Converge
      $global:FakeUsingSsl = 0

      $null = & $script:Invoke

      $global:FakeWsusUtilCalls | Should -Be 1
      $global:Ansible.Result.changed | Should -BeTrue
    }
  }

  Context 'inputs this role does not control' {

    It 'refuses when the pinned certificate is not in the machine store' {
      $global:FakeCertMissing = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*is in LocalMachine\My*'
      $global:FakeBindCalls | Should -Be 0
    }

    It 'refuses a certificate imported without its private key' {
      $global:FakeCertHasKey = $false

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*without its private key*'
      $global:FakeBindCalls | Should -Be 0
    }

    # Two clean runs cannot catch this: an expired certificate stays bound and reads as converged
    # while every client rejects the listener.
    It 'refuses an expired certificate' {
      $global:FakeCertNotAfter = (Get-Date).AddDays(-1)

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*expired*'
      $global:FakeBindCalls | Should -Be 0
    }

    It 'refuses a host whose WSUS post-installation never ran' {
      $global:FakeSetupMissing = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*Setup key is absent*'
    }
  }

  Context 'the host has to keep what it was told' {

    It 'fails when the listener does not keep the certificate' {
      $global:FakeBindingDrops = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*did not keep the pinned certificate*'
    }

    It 'fails when a directory does not keep the flag' {
      $global:FakeFlagDrops = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*does not require SSL*'
    }

    It 'fails when wsusutil exits non-zero' {
      $global:FakeWsusUtilExit = 1

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*exited 1*'
    }

    # The exit code is wsusutil's opinion; the registry is the server's.
    It 'fails when wsusutil succeeds and WSUS still records plain HTTP' {
      $global:FakeWsusUtilNoOp = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*still records itself as serving plain HTTP*'
    }

    It 'reports the change when only a directory was secured and the check then failed' {
      & $script:Converge
      $global:FakeSslFlags[('{0}/{1}' -f $script:Site, 'ClientWebService')] = ''
      $global:FakeFlagDrops = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*does not require SSL*'
      $global:Ansible.Changed | Should -BeTrue
    }

    # The three isolate ONE writer each, so that writer's own change report is the only thing
    # that can carry the flag. Without them a writer could stop reporting its change and the
    # neighbouring writer would cover for it -- and the host would be modified by a run that
    # ended saying it had modified nothing.
    It 'reports the change when only the listener was rewritten and the check then failed' {
      & $script:Converge
      $global:FakeBoundThumbprint = '0000000000000000000000000000000000000000'
      $global:FakeBindingDrops = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*did not keep the pinned certificate*'
      $global:Ansible.Changed | Should -BeTrue
    }

    It 'reports the change when only wsusutil ran and the check then failed' {
      & $script:Converge
      $global:FakeUsingSsl = 0
      $global:FakeWsusUtilNoOp = $true

      { & $script:Invoke } | Should -Throw -ExpectedMessage '*still records itself as serving plain HTTP*'
      $global:Ansible.Changed | Should -BeTrue
    }
  }

  Context 'refusals and the transport contract' {

    It 'declares SupportsShouldProcess, which is what makes the module run it under --check' {
      $Command = Get-Command -Name $script:ScriptPath
      $Command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }

    It 'writes nothing under -WhatIf' {
      $null = & $script:InvokeWhatIf

      $global:FakeBindCalls | Should -Be 0
      $global:FakeSecureCalls | Should -Be 0
      $global:FakeWsusUtilCalls | Should -Be 0
    }

    It 'still reports a change under -WhatIf, because the host needs one' {
      $null = & $script:InvokeWhatIf

      $global:Ansible.Result.changed | Should -BeTrue
    }
  }
}
