#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Set-IisLogDirectory.ps1 (org pair convention: every script ships with a
    sibling <Name>.pester.ps1; the pester-matrix workflow runs one leg per pair).

    Runs anywhere, Linux CI included. Every platform call the script makes -- the
    WebAdministration import, the two siteDefaults accessors, Get-Website, and the per-site
    Set-ItemProperty -- is stubbed around in-memory state, so the whole decision surface is
    exercised with no IIS present.

    Every write the script issues is recorded in $global:FakeIis.Writes. That is deliberate: this
    script's contract is "write only what differs", so the spec asserts on the writes themselves
    rather than on a changed flag that could be right for the wrong reason.

    Stub state lives in $global: variables because inside a function called from a child SCRIPT,
    $script: resolves to the child script's own scope, not this file's.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-IisLogDirectory.ps1'

    function Reset-FakeIis {
        param(
            [string]$DefaultsDirectory = 'C:\inetpub\logs\LogFiles',
            [bool]$DefaultsEnabled = $true,
            [object[]]$Sites = @(),
            [string[]]$ExistingPaths = @()
        )
        $global:FakeIis = [pscustomobject]@{
            DefaultsDirectory = $DefaultsDirectory
            DefaultsEnabled   = $DefaultsEnabled
            Sites             = $Sites
            ExistingPaths     = [System.Collections.Generic.List[string]]::new()
            Writes            = [System.Collections.Generic.List[string]]::new()
        }
        foreach ($p in $ExistingPaths) { $global:FakeIis.ExistingPaths.Add($p) }
    }

    function New-FakeSite {
        param([string]$Name, [string]$Directory, [bool]$Enabled = $true)
        [pscustomobject]@{
            Name    = $Name
            logFile = [pscustomobject]@{ directory = $Directory; enabled = $Enabled }
        }
    }

    # Invoke the script under test with every platform call stubbed.
    function Invoke-Script {
        param([string]$LogDirectory)

        $global:Ansible = [pscustomobject]@{
            Changed = $true; CheckMode = $false; Failed = $false; Result = $null
        }

        function global:Import-Module { param([Parameter(ValueFromRemainingArguments)]$Rest) }

        function global:Test-Path {
            param([Parameter(ValueFromRemainingArguments)]$Rest, [string]$LiteralPath)
            return $global:FakeIis.ExistingPaths -contains $LiteralPath
        }

        function global:New-Item {
            param([Parameter(ValueFromRemainingArguments)]$Rest, [string]$Path, [string]$ItemType, [switch]$Force)
            $global:FakeIis.Writes.Add("newitem:$Path")
            $global:FakeIis.ExistingPaths.Add($Path)
        }

        function global:Get-WebConfigurationProperty {
            param([string]$Filter, [string]$Name)
            if ($Name -eq 'directory') { return [pscustomobject]@{ Value = $global:FakeIis.DefaultsDirectory } }
            return [pscustomobject]@{ Value = $global:FakeIis.DefaultsEnabled }
        }

        function global:Set-WebConfigurationProperty {
            param([string]$Filter, [string]$Name, $Value)
            $global:FakeIis.Writes.Add("defaults:$Name=$Value")
            if ($Name -eq 'directory') { $global:FakeIis.DefaultsDirectory = [string]$Value }
            else { $global:FakeIis.DefaultsEnabled = [bool]$Value }
        }

        function global:Get-Website { return $global:FakeIis.Sites }

        function global:Set-ItemProperty {
            param([string]$LiteralPath, [string]$Name, $Value)
            $global:FakeIis.Writes.Add("site:$LiteralPath|$Name=$Value")
        }

        & $script:ScriptPath -LogDirectory $LogDirectory
        return $global:Ansible
    }
}

Describe 'Set-IisLogDirectory' {

    Context 'declared value validation' {
        It 'refuses a path carrying a %VAR% token' {
            Reset-FakeIis
            { Invoke-Script -LogDirectory '%SystemDrive%\inetpub\logs' } |
                Should -Throw -ExpectedMessage '*literal drive-qualified*'
        }

        It 'refuses a path that is not drive-qualified' {
            Reset-FakeIis
            { Invoke-Script -LogDirectory '\\server\share\logs' } |
                Should -Throw -ExpectedMessage '*literal drive-qualified*'
        }
    }

    Context 'a host that needs the whole change' {
        BeforeEach {
            Reset-FakeIis -DefaultsDirectory 'C:\inetpub\logs\LogFiles' -DefaultsEnabled $false -Sites @(
                (New-FakeSite -Name 'WSUS Administration' -Directory 'C:\inetpub\logs\LogFiles' -Enabled $false)
            )
            $script:Result = Invoke-Script -LogDirectory 'G:\inetpub\logs\LogFiles'
        }

        It 'reports changed' { $script:Result.Changed | Should -BeTrue }
        It 'creates the directory' { $global:FakeIis.Writes | Should -Contain 'newitem:G:\inetpub\logs\LogFiles' }
        It 'repoints siteDefaults' { $global:FakeIis.Writes | Should -Contain 'defaults:directory=G:\inetpub\logs\LogFiles' }
        It 'enables siteDefaults logging' { $global:FakeIis.Writes | Should -Contain 'defaults:enabled=True' }
        It 'repoints the existing site' {
            $global:FakeIis.Writes | Should -Contain 'site:IIS:\Sites\WSUS Administration|logFile.directory=G:\inetpub\logs\LogFiles'
        }
        It 'names the site it rewrote' {
            $script:Result.Result.sites | Should -Contain 'WSUS Administration'
        }
    }

    Context 'a converged host' {
        BeforeEach {
            Reset-FakeIis -DefaultsDirectory 'G:\inetpub\logs\LogFiles' -DefaultsEnabled $true `
                -ExistingPaths @('G:\inetpub\logs\LogFiles') -Sites @(
                    (New-FakeSite -Name 'WSUS Administration' -Directory 'G:\inetpub\logs\LogFiles' -Enabled $true)
                )
            $script:Result = Invoke-Script -LogDirectory 'G:\inetpub\logs\LogFiles'
        }

        It 'reports no change' { $script:Result.Changed | Should -BeFalse }
        It 'issues no writes at all' { $global:FakeIis.Writes.Count | Should -Be 0 }
        It 'names no rewritten site' { $script:Result.Result.sites.Count | Should -Be 0 }
    }

    Context 'forms IIS returns interchangeably' {
        It 'treats a trailing separator as converged' {
            Reset-FakeIis -DefaultsDirectory 'G:\inetpub\logs\LogFiles\' -DefaultsEnabled $true `
                -ExistingPaths @('G:\inetpub\logs\LogFiles') -Sites @(
                    (New-FakeSite -Name 'S' -Directory 'G:\inetpub\logs\LogFiles\' -Enabled $true)
                )
            (Invoke-Script -LogDirectory 'G:\inetpub\logs\LogFiles').Changed | Should -BeFalse
        }

        It 'treats forward slashes and case as converged' {
            Reset-FakeIis -DefaultsDirectory 'g:/inetpub/logs/logfiles' -DefaultsEnabled $true `
                -ExistingPaths @('G:\inetpub\logs\LogFiles') -Sites @(
                    (New-FakeSite -Name 'S' -Directory 'G:/INETPUB/logs/LogFiles' -Enabled $true)
                )
            (Invoke-Script -LogDirectory 'G:\inetpub\logs\LogFiles').Changed | Should -BeFalse
        }
    }

    Context 'a token already in the configuration' {
        It 'counts a %VAR% current value as drift even when it would expand correctly' {
            Reset-FakeIis -DefaultsDirectory '%SystemDrive%\inetpub\logs\LogFiles' -DefaultsEnabled $true `
                -ExistingPaths @('G:\inetpub\logs\LogFiles') -Sites @()
            $r = Invoke-Script -LogDirectory 'G:\inetpub\logs\LogFiles'
            $r.Changed | Should -BeTrue
            $global:FakeIis.Writes | Should -Contain 'defaults:directory=G:\inetpub\logs\LogFiles'
        }
    }

    Context 'more than one site' {
        It 'rewrites only the sites that differ' {
            Reset-FakeIis -DefaultsDirectory 'G:\inetpub\logs\LogFiles' -DefaultsEnabled $true `
                -ExistingPaths @('G:\inetpub\logs\LogFiles') -Sites @(
                    (New-FakeSite -Name 'Settled' -Directory 'G:\inetpub\logs\LogFiles' -Enabled $true),
                    (New-FakeSite -Name 'Drifted' -Directory 'C:\inetpub\logs\LogFiles' -Enabled $true)
                )
            $r = Invoke-Script -LogDirectory 'G:\inetpub\logs\LogFiles'
            $r.Result.sites | Should -Be @('Drifted')
            $global:FakeIis.Writes | Should -Not -Contain 'site:IIS:\Sites\Settled|logFile.directory=G:\inetpub\logs\LogFiles'
        }
    }
}
