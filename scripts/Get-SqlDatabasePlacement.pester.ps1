#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Get-SqlDatabasePlacement.ps1 (org pair convention: every script ships with a
    sibling <Name>.pester.ps1; the pester-matrix workflow runs one leg per pair).

    Runs anywhere, Linux CI included. Get-CimInstance, Get-ItemProperty and Get-Acl do not exist
    off Windows and the SQL and principal APIs refuse to work there, so the script confines every
    platform call to those three cmdlets plus New-Object -- which this file stubs around in-memory
    state. That exercises the whole decision surface (stopped, unregistered, misplaced, denied,
    non-inheritable) with no SQL Server, no NTFS and no registry.

    Stub state lives in $global: variables because inside a function called from a child SCRIPT,
    $script: resolves to the child script's own scope, not this file's.

    Both transports are asserted: the standalone JSON emission and the $Ansible path via the inline
    context below (pairs are self-contained; no imports). Its Changed defaults to $True exactly
    like win_powershell -- so the spec proves the script SETS Changed rather than inheriting it.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Get-SqlDatabasePlacement.ps1'
  $script:Data = 'E:\MSSQL\Data'
  $script:Log = 'E:\MSSQL\Log'
  $script:Sid = 'S-1-5-80-3880718306-3832830129-1677859214-2598158968-1052248003'
  $script:SettingsKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer'
  $script:NamesKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
  $script:Root = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'

  $script:Invoke = {
    & $script:ScriptPath `
      -ServiceName 'MSSQLSERVER' -InstanceName 'MSSQLSERVER' `
      -InstanceNamesKey $script:NamesKey `
      -InstanceRoot $script:Root `
      -DesiredData $script:Data -DesiredLog $script:Log
  }

  # The transport does not just set $Ansible.CheckMode: because this script declares
  # SupportsShouldProcess, win_powershell also passes -WhatIf. Only this invoker reproduces the
  # second half, and without it the neutralising assignment in the script is pinned by nothing.
  $script:InvokeWhatIf = {
    & $script:ScriptPath `
      -ServiceName 'MSSQLSERVER' -InstanceName 'MSSQLSERVER' `
      -InstanceNamesKey $script:NamesKey `
      -InstanceRoot $script:Root `
      -DesiredData $script:Data -DesiredLog $script:Log -WhatIf
  }

  # An access rule as Get-Acl hands it back when asked for SID-form identities.
  Function New-Rule {
    Param (
      [System.String]$Sid,
      [System.String]$Type = 'Allow',
      [System.Object]$Rights = [System.Security.AccessControl.FileSystemRights]::FullControl,
      [System.Object]$Inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
      [System.Object]$Propagation = [System.Security.AccessControl.PropagationFlags]::None
    )
    [PSCustomObject]@{
      IdentityReference = [PSCustomObject]@{ Value = $Sid }
      AccessControlType = $Type
      FileSystemRights  = $Rights
      InheritanceFlags  = $Inheritance
      PropagationFlags  = $Propagation
    }
  }

  # Inline $Ansible stand-in (org contract: pairs are self-contained, no imports). Faithful to
  # win_powershell: Changed defaults to $True, and only the ratified surface is modeled.
  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{
      Changed   = $True
      CheckMode = $CheckMode.IsPresent
      Failed    = $False
      Result    = $Null
    }
    $global:Ansible
  }

  Function Remove-AnsibleContext {
    Remove-Variable -Name 'Ansible' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  # Answers only the class and the service the script is supposed to ask for. A stub that ignored
  # its inputs would let the script query the wrong class, or some other service, and still pass.
  Function Get-CimInstance {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$ClassName, [Parameter()] [System.String]$Filter)
    $global:FakeCimAsked = [PSCustomObject]@{ ClassName = $ClassName; Filter = $Filter }
    If ($ClassName -cne 'Win32_Service') { Return $Null }
    If ($Filter -cne ("Name='{0}'" -f $global:FakeServiceName)) { Return $Null }
    If ($global:FakeServiceMissing) { Return $Null }
    [PSCustomObject]@{
      State     = $global:FakeServiceState
      StartMode = $global:FakeServiceStartMode
    }
  }

  # Keyed off the path, so reading the wrong registry key returns an object with no instances on
  # it rather than the right answer by accident.
  Function Get-ItemProperty {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$LiteralPath)
    $global:FakeRegistryReads += $LiteralPath
    $Object = [PSCustomObject]@{}
    If ($global:FakeRegistry.ContainsKey($LiteralPath)) {
      ForEach ($Name in $global:FakeRegistry[$LiteralPath].Keys) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $global:FakeRegistry[$LiteralPath][$Name]
      }
    }
    Return $Object
  }

  Function Test-Path {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$LiteralPath)
    Return ($global:FakePaths -contains $LiteralPath)
  }

  Function Get-Acl {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$LiteralPath)
    $global:FakeAclReads++
    $global:FakeAclCurrent = @($global:FakeAcl[$LiteralPath])
    $Descriptor = [PSCustomObject]@{}
    $Descriptor | Add-Member -MemberType ScriptMethod -Name 'GetAccessRules' -Value {
      Param ([System.Object]$Explicit, [System.Object]$Inherited, [System.Object]$TargetType)
      $global:FakeAclAskedFor = [PSCustomObject]@{
        Explicit = $Explicit; Inherited = $Inherited; TargetType = $TargetType
      }
      $global:FakeAclCurrent
    }
    Return $Descriptor
  }

  Function New-Object {
    [CmdletBinding()]
    Param ([Parameter()] [System.String]$TypeName, [Parameter()] [System.Object]$ArgumentList)

    If ($TypeName -like '*SqlConnection') {
      # Recorded: WHICH engine the script talks to has to match the service PROCESS restarts,
      # or the role reads one instance's placement while repointing another's.
      $global:FakeConnectionString = [System.String]$ArgumentList
      $Connection = [PSCustomObject]@{}
      $Connection | Add-Member -MemberType ScriptMethod -Name 'Open' -Value {
        If ($global:FakeConnectionRefused) {
          Throw 'A network-related or instance-specific error occurred while establishing a connection.'
        }
        $global:FakeOpens++
      }
      $Connection | Add-Member -MemberType ScriptMethod -Name 'Close' -Value { $global:FakeCloses++ }
      $Connection | Add-Member -MemberType ScriptMethod -Name 'CreateCommand' -Value {
        $Command = [PSCustomObject]@{ CommandText = '' }
        $Command | Add-Member -MemberType ScriptMethod -Name 'ExecuteScalar' -Value {
          If ($this.CommandText -match 'InstanceDefaultDataPath') { Return $global:FakeDataPath }
          If ($this.CommandText -match 'InstanceDefaultLogPath') { Return $global:FakeLogPath }
          If ($this.CommandText -match 'COUNT\(\*\).*master_files') { Return $global:FakeSusdbFileCount }
          If ($this.CommandText -match "master_files.*type_desc = 'ROWS'") { Return $global:FakeSusdbData }
          If ($this.CommandText -match "master_files.*type_desc = 'LOG'") { Return $global:FakeSusdbLog }
          If ($this.CommandText -match 'state_desc FROM sys\.databases') { Return $global:FakeSusdbState }
          If ($this.CommandText -match 'is_read_only.*FROM sys\.databases') { Return $global:FakeSusdbReadOnly }
          Throw ('Unexpected query: {0}' -f $this.CommandText)
        }
        Return $Command
      }
      Return $Connection
    }

    If ($TypeName -like '*NTAccount') {
      # Recorded, because WHICH principal the script translates is the whole point of the grant:
      # a script asking for BUILTIN\Administrators would otherwise satisfy every other assertion.
      $global:FakeAccountRequested = [System.String]$ArgumentList
      $Account = [PSCustomObject]@{ Name = [System.String]$ArgumentList }
      $Account | Add-Member -MemberType ScriptMethod -Name 'Translate' -Value {
        Param ([System.Object]$TargetType)
        [PSCustomObject]@{ Value = $global:FakeServiceSid }
      }
      Return $Account
    }

    Throw ('Unexpected New-Object type: {0}' -f $TypeName)
  }
}

Describe 'Get-SqlDatabasePlacement' {

  BeforeEach {
    $global:FakeServiceMissing = $False
    $global:FakeServiceName = 'MSSQLSERVER'
    $global:FakeServiceState = 'Running'
    $global:FakeServiceStartMode = 'Auto'
    $global:FakeRegistry = @{
      $script:NamesKey = @{ 'MSSQLSERVER' = 'MSSQL16.MSSQLSERVER' }
    }
    $global:FakeRegistryReads = @()
    $global:FakeAclAskedFor = $Null
    $global:FakeConnectionString = ''
    $global:FakeAccountRequested = ''
    $global:FakeCimAsked = $Null
    $global:FakePaths = @($script:SettingsKey, $script:Data, $script:Log)
    # The engine reports a trailing separator; the script is expected to trim it.
    $global:FakeDataPath = ($script:Data + '\')
    $global:FakeLogPath = ($script:Log + '\')
    $global:FakeSusdbData = ($script:Data + '\SUSDB.mdf')
    $global:FakeSusdbLog = ($script:Log + '\SUSDB_log.ldf')
    $global:FakeSusdbFileCount = 2
    $global:FakeSusdbState = 'ONLINE'
    $global:FakeSusdbReadOnly = 0
    $global:FakeServiceSid = $script:Sid
    $global:FakeAcl = @{
      $script:Data = @(New-Rule -Sid $script:Sid)
      $script:Log  = @(New-Rule -Sid $script:Sid)
    }
    $global:FakeConnectionRefused = $False
    $global:FakeOpens = 0
    $global:FakeCloses = 0
    $global:FakeAclReads = 0
    $global:FakeAclCurrent = @()
    Remove-AnsibleContext
  }

  AfterAll {
    Remove-AnsibleContext
    Remove-Variable -Scope 'Global' -Force -ErrorAction 'SilentlyContinue' -Name @(
      'FakeServiceMissing', 'FakeServiceName', 'FakeServiceState', 'FakeServiceStartMode',
      'FakeRegistry', 'FakeRegistryReads', 'FakeAclAskedFor', 'FakeConnectionString',
      'FakeAccountRequested', 'FakeCimAsked', 'FakePaths', 'FakeDataPath', 'FakeLogPath',
      'FakeSusdbData', 'FakeSusdbLog', 'FakeSusdbFileCount', 'FakeSusdbState', 'FakeSusdbReadOnly',
      'FakeServiceSid', 'FakeAcl', 'FakeConnectionRefused', 'FakeOpens', 'FakeCloses',
      'FakeAclReads', 'FakeAclCurrent'
    )
  }

  Context 'a converged host' {

    It 'reports the placement valid, trims the trailing separator, and closes the connection' {
      $Result = & $script:Invoke | ConvertFrom-Json

      $Result.placement_valid | Should -BeTrue
      $Result.effective_data | Should -Be $script:Data
      $Result.effective_log | Should -Be $script:Log
      $Result.settings_key | Should -Be $script:SettingsKey
      $Result.service_state | Should -Be 'Running'
      $Result.service_start_mode | Should -Be 'Auto'
      $global:FakeCloses | Should -Be 1
    }

    It 'reports both directories granted and neither denied' {
      $Result = & $script:Invoke | ConvertFrom-Json

      $Result.data_acl_granted | Should -BeTrue
      $Result.log_acl_granted | Should -BeTrue
      $Result.data_acl_denied | Should -BeFalse
      $Result.log_acl_denied | Should -BeFalse
    }

    It 'never reports a change, even though the transport defaults Changed to true' {
      $Context = New-AnsibleContext
      $null = & $script:Invoke

      $Context.Changed | Should -BeFalse
      $Context.Result.placement_valid | Should -BeTrue
    }
  }

  Context 'an instance that cannot answer' {

    It 'reads a stopped instance instead of failing, and asks it nothing' {
      $global:FakeServiceState = 'Stopped'
      $global:FakeServiceStartMode = 'Manual'

      $Result = & $script:Invoke | ConvertFrom-Json

      $Result.placement_valid | Should -BeFalse
      $Result.effective_data | Should -BeNullOrEmpty
      $Result.service_state | Should -Be 'Stopped'
      $Result.service_start_mode | Should -Be 'Manual'
      $global:FakeOpens | Should -Be 0
    }

    It 'fails when the service is not installed at all' {
      $global:FakeServiceMissing = $True

      { & $script:Invoke } | Should -Throw '*is not installed on this host*'
    }

    It 'surfaces a refused connection rather than reporting a placement' {
      $global:FakeConnectionRefused = $True

      { & $script:Invoke } | Should -Throw '*establishing a connection*'
    }
  }

  Context 'an instance this role cannot address' {

    It 'names the instances it did find when the requested one is absent' {
      $global:FakeRegistry[$script:NamesKey] = @{ 'SQLEXPRESS' = 'MSSQL16.SQLEXPRESS' }

      { & $script:Invoke } | Should -Throw '*Known instances: SQLEXPRESS*'
    }

    It 'refuses to report a settings key that does not exist' {
      $global:FakePaths = @($script:Data, $script:Log)

      { & $script:Invoke } | Should -Throw '*has no settings key*'
    }
  }

  Context 'placement the engine has not adopted' {

    It 'reports invalid when the engine still names the system volume' {
      $global:FakeDataPath = 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\'

      $Result = & $script:Invoke | ConvertFrom-Json

      $Result.placement_valid | Should -BeFalse
      $Result.effective_data | Should -Be 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA'
    }

    It 'accepts the engine naming the same directories in a different case' {
      $global:FakeDataPath = 'e:\mssql\data\'
      $global:FakeLogPath = 'E:\MSSQL\LOG'

      (& $script:Invoke | ConvertFrom-Json).placement_valid | Should -BeTrue
    }

    It 'reports invalid when only the log directory disagrees' {
      $global:FakeLogPath = 'C:\Wrong\Log\'

      (& $script:Invoke | ConvertFrom-Json).placement_valid | Should -BeFalse
    }
  }

  Context 'access the engine does not really have' {

    It 'does not count a grant that stops at the folder' {
      $global:FakeAcl[$script:Data] = @(
        New-Rule -Sid $script:Sid -Inheritance ([System.Security.AccessControl.InheritanceFlags]::None)
      )

      $Result = & $script:Invoke | ConvertFrom-Json

      $Result.data_acl_granted | Should -BeFalse
      $Result.log_acl_granted | Should -BeTrue
    }

    It 'does not count a grant carrying only <Flag> of the two inheritance flags' -ForEach @(
      @{ Flag = 'ContainerInherit' }   # subdirectories inherit, the .mdf and .ldf files do not
      @{ Flag = 'ObjectInherit' }      # files inherit, subdirectories do not
    ) {
      $global:FakeAcl[$script:Data] = @(
        New-Rule -Sid $script:Sid -Inheritance ([System.Security.AccessControl.InheritanceFlags]$Flag)
      )

      (& $script:Invoke | ConvertFrom-Json).data_acl_granted | Should -BeFalse
    }

    It 'does not count a grant that applies only to children and not the folder' {
      $global:FakeAcl[$script:Data] = @(
        New-Rule -Sid $script:Sid -Propagation ([System.Security.AccessControl.PropagationFlags]::InheritOnly)
      )

      (& $script:Invoke | ConvertFrom-Json).data_acl_granted | Should -BeFalse
    }

    It 'does not count a grant short of FullControl' {
      $global:FakeAcl[$script:Data] = @(
        New-Rule -Sid $script:Sid -Rights ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute)
      )

      (& $script:Invoke | ConvertFrom-Json).data_acl_granted | Should -BeFalse
    }

    It 'does not count a grant belonging to some other principal' {
      $global:FakeAcl[$script:Data] = @(New-Rule -Sid 'S-1-5-32-544')

      (& $script:Invoke | ConvertFrom-Json).data_acl_granted | Should -BeFalse
    }

    It 'reports a deny naming the service itself' {
      $global:FakeAcl[$script:Data] = @(
        New-Rule -Sid $script:Sid
        New-Rule -Sid $script:Sid -Type 'Deny'
      )

      (& $script:Invoke | ConvertFrom-Json).data_acl_denied | Should -BeTrue
    }

    It 'does not count a Deny entry as though it were a grant' {
      $global:FakeAcl[$script:Data] = @(New-Rule -Sid $script:Sid -Type 'Deny')

      $Result = & $script:Invoke | ConvertFrom-Json

      $Result.data_acl_granted | Should -BeFalse
      $Result.data_acl_denied | Should -BeTrue
    }

    It 'reports a deny naming every service process, which the engine is one of' {
      $global:FakeAcl[$script:Data] = @(
        New-Rule -Sid $script:Sid
        New-Rule -Sid 'S-1-5-80-0' -Type 'Deny'
      )

      (& $script:Invoke | ConvertFrom-Json).data_acl_denied | Should -BeTrue
    }

    It 'reports a deny naming <Sid>, which a service token carries' -ForEach @(
      @{ Sid = 'S-1-1-0' }        # Everyone
      @{ Sid = 'S-1-2-0' }        # LOCAL
      @{ Sid = 'S-1-2-1' }        # CONSOLE LOGON
      @{ Sid = 'S-1-5-32-558' }   # BUILTIN\Performance Monitor Users
      @{ Sid = 'S-1-5-6' }        # NT AUTHORITY\SERVICE
      @{ Sid = 'S-1-5-11' }       # NT AUTHORITY\Authenticated Users
      @{ Sid = 'S-1-5-15' }       # NT AUTHORITY\This Organization
      @{ Sid = 'S-1-5-32-545' }   # BUILTIN\Users
      @{ Sid = 'S-1-5-80-0' }     # NT SERVICE\ALL SERVICES
    ) {
      $global:FakeAcl[$script:Log] = @(
        New-Rule -Sid $script:Sid
        New-Rule -Sid $Sid -Type 'Deny'
      )

      $Result = & $script:Invoke | ConvertFrom-Json

      $Result.log_acl_denied | Should -BeTrue
      $Result.log_acl_granted | Should -BeTrue
    }

    It 'reports a deny of only SOME of the rights, not just a full-control deny' {
      $global:FakeAcl[$script:Data] = @(
        New-Rule -Sid $script:Sid
        New-Rule -Sid $script:Sid -Type 'Deny' -Rights ([System.Security.AccessControl.FileSystemRights]::Write)
      )

      (& $script:Invoke | ConvertFrom-Json).data_acl_denied | Should -BeTrue
    }

    It 'ignores a deny naming a principal the service is not' {
      $global:FakeAcl[$script:Data] = @(
        New-Rule -Sid $script:Sid
        New-Rule -Sid 'S-1-5-21-1-2-3-1001' -Type 'Deny'
      )

      (& $script:Invoke | ConvertFrom-Json).data_acl_denied | Should -BeFalse
    }

    It 'reports no access for a directory that does not exist yet' {
      $global:FakePaths = @($script:SettingsKey, $script:Log)

      $Result = & $script:Invoke | ConvertFrom-Json

      $Result.data_acl_granted | Should -BeFalse
      $Result.data_acl_denied | Should -BeFalse
    }
  }

  Context 'what the script asks the machine for' {

    It 'translates the instance per-service account, not some other principal' {
      $null = & $script:Invoke | ConvertFrom-Json

      $global:FakeAccountRequested | Should -Be 'NT SERVICE\MSSQLSERVER'
    }

    It 'reads the instance directory from the instance-names key, not the instance root' {
      $null = & $script:Invoke | ConvertFrom-Json

      $global:FakeRegistryReads | Should -Contain $script:NamesKey
      $global:FakeRegistryReads | Should -Not -Contain $script:Root
    }

    It 'asks the service control manager for the named service' {
      $null = & $script:Invoke | ConvertFrom-Json

      $global:FakeCimAsked.ClassName | Should -Be 'Win32_Service'
      $global:FakeCimAsked.Filter | Should -Be "Name='MSSQLSERVER'"
    }

    It 'connects to the default instance, the same engine the caller restarts' {
      $null = & $script:Invoke | ConvertFrom-Json

      $global:FakeConnectionString | Should -Match '(^|;)\s*Server=\.\s*;'
    }

    It 'declares SupportsShouldProcess, which is what makes the module run it under --check' {
      $Source = Get-Content -LiteralPath $script:ScriptPath -Raw

      $Source | Should -Match '\[CmdletBinding\(SupportsShouldProcess\)\]'
    }
  }

  Context 'how it asks for the access rules' {

    It 'asks for SID identities and includes inherited rules' {
      $null = & $script:Invoke | ConvertFrom-Json

      $global:FakeAclAskedFor.Inherited | Should -BeTrue
      $global:FakeAclAskedFor.TargetType | Should -Be ([System.Security.Principal.SecurityIdentifier])
    }
  }

  Context 'whether the engine could be asked at all' {

    It 'reports the placement as read on a running instance' {
      (& $script:Invoke | ConvertFrom-Json).placement_read | Should -BeTrue
    }

    It 'reports a running instance as READ even when it names the wrong directory' {
      # The one state the caller's restart decision turns on: the engine answered, and disagreed.
      # Without this, tying placement_read to the verdict instead of to reachability goes unseen.
      $global:FakeDataPath = 'C:\Wrong\Data\'

      $Result = & $script:Invoke | ConvertFrom-Json

      $Result.placement_read | Should -BeTrue
      $Result.placement_valid | Should -BeFalse
    }

    It 'reports the placement as UNREAD on a stopped instance, not merely invalid' {
      $global:FakeServiceState = 'Stopped'

      $Result = & $script:Invoke | ConvertFrom-Json

      $Result.placement_read | Should -BeFalse
      $Result.placement_valid | Should -BeFalse
    }
  }

  Context 'the transport contract' {

    It 'reports check mode back to the caller' {
      $Context = New-AnsibleContext -CheckMode
      $null = & $script:Invoke

      $Context.Result.check_mode | Should -BeTrue
    }

    # -WhatIf would otherwise suppress the New-Variable setup the script indexes into
    # immediately afterwards, so check mode would die in BEGIN before reading anything.
    It 'still reads the machine when the transport injects -WhatIf' {
      $Context = New-AnsibleContext -CheckMode
      $null = & $script:InvokeWhatIf

      $Context.Result.placement_valid | Should -BeTrue
    }

    It 'leaves Changed false when it throws, rather than inheriting the transport default' {
      $Context = New-AnsibleContext
      $global:FakeServiceMissing = $True

      { & $script:Invoke } | Should -Throw

      $Context.Changed | Should -BeFalse
    }
  }

  Context 'where the engine actually has SUSDB' {

    It 'reports the file paths the engine has the database attached from' {
      $Result = & $script:Invoke | ConvertFrom-Json

      $Result.susdb_data_path | Should -Be 'E:\MSSQL\Data\SUSDB.mdf'
      $Result.susdb_log_path | Should -Be 'E:\MSSQL\Log\SUSDB_log.ldf'
      $Result.susdb_file_count | Should -Be 2
    }

    # A first converge has no such database, and DB_ID returns null rather than raising. The
    # caller must be able to tell that apart from a database attached somewhere unexpected.
    It 'reports empty paths and no files when the database does not exist' {
      $global:FakeSusdbData = $Null
      $global:FakeSusdbLog = $Null
      $global:FakeSusdbFileCount = 0

      $Result = & $script:Invoke | ConvertFrom-Json

      $Result.susdb_data_path | Should -BeNullOrEmpty
      $Result.susdb_log_path | Should -BeNullOrEmpty
      $Result.susdb_file_count | Should -Be 0
    }

    It 'reports a database attached from somewhere else verbatim, rather than hiding it' {
      $global:FakeSusdbData = 'C:\SUSDB.mdf'

      (& $script:Invoke | ConvertFrom-Json).susdb_data_path | Should -Be 'C:\SUSDB.mdf'
    }

    # Where the files are and whether the database can serve are different questions, and
    # post-installation would build on an attached database that cannot.
    It 'reports whether the database can actually serve' {
      $Result = & $script:Invoke | ConvertFrom-Json

      $Result.susdb_state | Should -Be 'ONLINE'
      $Result.susdb_read_only | Should -Be 0
    }

    It 'reports a database recovering from an unclean stop as such' {
      $global:FakeSusdbState = 'RECOVERY_PENDING'

      (& $script:Invoke | ConvertFrom-Json).susdb_state | Should -Be 'RECOVERY_PENDING'
    }

    # -1, not 0: a database that does not exist is not a writable one.
    It 'reports no state and no read-only answer when the database does not exist' {
      $global:FakeSusdbState = $Null

      $Result = & $script:Invoke | ConvertFrom-Json

      $Result.susdb_state | Should -BeNullOrEmpty
      $Result.susdb_read_only | Should -Be -1
    }

    # The path scalars report the FIRST file of each kind, so an extra data file elsewhere leaves
    # both of them reading correctly; only the count sees it.
    It 'reports a file count above the pair the role creates' {
      $global:FakeSusdbFileCount = 3

      (& $script:Invoke | ConvertFrom-Json).susdb_file_count | Should -Be 3
    }

    It 'reports nothing about SUSDB when the instance is not running' {
      $global:FakeServiceState = 'Stopped'

      $Result = & $script:Invoke | ConvertFrom-Json

      $Result.susdb_data_path | Should -BeNullOrEmpty
      $Result.susdb_file_count | Should -Be 0
    }
  }

  Context 'the two directories are reported separately' {

    It 'does not let one directory report the other access' {
      $global:FakeAcl[$script:Data] = @(New-Rule -Sid $script:Sid)
      $global:FakeAcl[$script:Log] = @(New-Rule -Sid 'S-1-5-32-544')

      $Result = & $script:Invoke | ConvertFrom-Json

      $Result.data_acl_granted | Should -BeTrue
      $Result.log_acl_granted | Should -BeFalse
      $global:FakeAclReads | Should -Be 2
    }
  }
}
