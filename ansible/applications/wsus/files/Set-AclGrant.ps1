#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Sets one identity's access on a path to exactly what is declared, and nothing else.

    .DESCRIPTION
        win_acl adds. That is the whole reason this exists: adding an allow leaves a DENY on the
        same identity untouched, and Windows evaluates deny first -- so a converge can add the
        grant, report changed, and leave the account unable to write. Measured on a live host:
        with a deny of WriteData present, the allow entry is still printed by icacls exactly as
        before, and the account still cannot write.

        So this does not add. For the identity it is given, it PURGES every explicit entry on the
        path -- allow and deny alike -- and writes back the single declared allow. Afterwards that
        identity's access on this path is exactly what was asked for, whatever it was before, which
        is what makes the result independent of history.

        Two limits, both deliberate.

        Inherited entries are left alone, because they are not this path's to remove. An inherited
        DENY that intersects the declared rights therefore cannot be repaired here, and the script
        refuses rather than reporting a success it cannot deliver -- the parent has to be fixed.

        Other identities are left alone. This owns one identity's access, not the descriptor.

    .PARAMETER DebugLevel
        Three digits: ErrorActionPreference, Set-PSDebug, Set-StrictMode.

    .PARAMETER LogLevel
        Six digits, one per stream: Verbose, Debug, Information, Warning, Error, Fatal.

    .PARAMETER Path
        The filesystem path whose access control list is written.

    .PARAMETER Sid
        The identity to set, in SDDL string form -- 'S-1-5-20' for NETWORK SERVICE. A well-known
        SID is identical on every Windows install in every language, unlike the display name.

    .PARAMETER Rights
        The FileSystemRights to grant, as the enum's own names -- 'FullControl'.

    .PARAMETER Inheritance
        The InheritanceFlags for the entry, as the enum's own names --
        'ContainerInherit, ObjectInherit' for a tree, 'None' for the path alone.

    .EXAMPLE
        Set-AclGrant.ps1 -Path 'F:\WSUS\WsusContent' -Sid 'S-1-5-20' -Rights 'FullControl'
            -Inheritance 'ContainerInherit, ObjectInherit'

    .OUTPUTS
        One object carrying changed, check_mode, msg, purged and sid.

        purged counts the explicit entries removed for this identity, so a caller can see whether
        the run replaced something or wrote the first entry.
#>

[CmdletBinding(SupportsShouldProcess)]
[OutputType([System.Void])]
Param (
  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[0-5][0-4][0-3]$')]
  [System.String]
  $DebugLevel = '103',

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String]
  $LogLevel = '002223',

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $Path,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^S-1-[0-9-]+$')]
  [System.String]
  $Sid,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $Rights,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $Inheritance
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

# The module runs this script in check mode because it declares SupportsShouldProcess, and injects
# -WhatIf when it does. A read has nothing to suppress, and -WhatIf left on would suppress the
# New-Variable setup below, so it is neutralised here exactly as in the sibling scripts.
$WhatIfPreference = $false

# Initialize STATIC log level names, indexed by LogLevel digit position.
New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)

# Initialize the custom stream preferences; the built-in ones already exist.
New-Variable -Verbose:$False -Force -Name:'ErrorPreference' -Value:(
  [System.Management.Automation.ActionPreference]::Stop
)
New-Variable -Verbose:$False -Force -Name:'FatalPreference' -Value:(
  [System.Management.Automation.ActionPreference]::Stop
)

# Configure log levels based on the LogLevel parameter.
For ($L = 0; $L -lt 6; $L++) {
  Set-Variable -Verbose:$False -Force -Name:('{0}Preference' -f $LOG_LEVELS[$L]) -Value:(
    [System.Int32]::Parse([System.String]$LogLevel[$L]) -as [System.Management.Automation.ActionPreference]
  )
}

# Configure the debug levels: first digit ErrorActionPreference, second digit
# Set-PSDebug, third digit Set-StrictMode.
$ErrorActionPreference = [System.Management.Automation.ActionPreference][System.Int32]::Parse($DebugLevel.Substring(0, 1))
Switch ($DebugLevel.Substring(1, 1)) {
  '0' { Set-PSDebug -Off }
  '1' { Set-PSDebug -Trace:1 }
  '2' { Set-PSDebug -Trace:2 }
  '3' { Set-PSDebug -Trace:1 -Step }
  '4' { Set-PSDebug -Trace:2 -Step }
}
If ($DebugLevel.Substring(2, 1) -eq '0') {
  Set-StrictMode -Off
} Else {
  Set-StrictMode -Version:([System.String]$DebugLevel.Substring(2, 1))
}

# Universal trap used to help with debugging efforts. The original template's
# Wait-Debugger/Exit are interactive-host machinery; under the Ansible
# transport the trap logs and rethrows (Break) so the task fails honestly.
Trap {
  # The failure text is emitted FIRST and on its own. A bare `Throw '<string>'` leaves
  # InvocationInfo null on the inner ErrorRecord, and reaching into it under StrictMode raises a
  # property error that the surrounding Catch would swallow -- costing the operator the real
  # failure and printing 'diagnostics unavailable' in its place. Order is the whole fix.
  Try {
    Write-Warning -Message:(
      '[{0:0000}] {1} [{2}]' -f @(
        [System.Int64]$PSItem.InvocationInfo.ScriptLineNumber
        [System.String]$PSItem.Exception.Message
        [System.String]$PSItem.Exception.GetBaseException().GetType().FullName
      )
    )
  } Catch {
    Write-Warning -Message:'Trap could not render the failure text for this error record.'
  }

  # The invoking line is a nicety, attempted separately and null-guarded at every hop.
  Try {
    $Record = $PSItem.Exception.PSObject.Properties['ErrorRecord']
    If ($Null -ne $Record -and $Null -ne $Record.Value -and $Null -ne $Record.Value.InvocationInfo) {
      Write-Debug -Message:('Failed to execute command: {0}' -f [System.String]$Record.Value.InvocationInfo.Line)
    }
  } Catch {
    Write-Debug -Message:'Trap diagnostics unavailable for this error record.'
  }

  Break
}

# Under win_powershell the transport provides $Ansible; standalone (a dev
# shell or a Pester spec) it does not, so the script creates a faithful stub.
$StandaloneRun = $Null -eq (Get-Variable -Name:'Ansible' -ValueOnly -ErrorAction:'SilentlyContinue')
If ($StandaloneRun) {
  $Ansible = [PSCustomObject]@{
    Changed   = $True
    CheckMode = $False
    Failed    = $False
    Result    = $Null
  }
}

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

# The transport seeds Changed true. Nothing is written yet, and a throw below must not report a
# change this run never made.
$Ansible.Changed = $False

$RequiredValue = [System.Int32][System.Security.AccessControl.FileSystemRights]$Rights

# New-Object rather than a type cast, so a specification can stand in for it. The .NET types this
# needs cannot be constructed off Windows, which is the only reason the shape matters here.
$SidObject = New-Object -TypeName:'System.Security.Principal.SecurityIdentifier' -ArgumentList:$Sid

$Acl = Get-Acl -Path:$Path

$ExplicitAllow = 0
$ExplicitDeny = 0
$InheritedDeny = 0
$ExplicitCount = 0
$InheritanceMatches = $False

ForEach ($Ace In @($Acl.Access)) {
  $AceSid = ''
  Try {
    $AceSid = [System.String]$Ace.IdentityReference.Translate(
      [System.Security.Principal.SecurityIdentifier]
    ).Value
  } Catch {
    $AceSid = [System.String]$Ace.IdentityReference.Value
  }

  If ($AceSid -ne $Sid) { Continue }

  $AceRights = [System.Int32]$Ace.FileSystemRights
  $IsDeny = ($Ace.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny)

  If ($Ace.IsInherited) {
    If ($IsDeny) { $InheritedDeny = $InheritedDeny -bor $AceRights }
    Continue
  }

  $ExplicitCount++
  If ($IsDeny) {
    $ExplicitDeny = $ExplicitDeny -bor $AceRights
  } Else {
    $ExplicitAllow = $ExplicitAllow -bor $AceRights
    If ([System.String]$Ace.InheritanceFlags -eq $Inheritance) { $InheritanceMatches = $True }
  }
}

# Refused rather than reported converged. An inherited deny defeats the grant and cannot be
# removed from here -- only from the parent that carries it -- so writing the allow and returning
# success would report access this script did not deliver.
If (($InheritedDeny -band $RequiredValue) -ne 0) {
  Throw (
    'An inherited deny on {0} withholds part of {1} from {2}. It cannot be removed from this path; the parent carrying it must be repaired.' -f
    $Path, $Rights, $Sid
  )
}

# Already correct means all three: the rights are covered, the entry carries the declared
# inheritance, and no explicit deny is standing against it.
$AlreadyCorrect = (
  (($ExplicitAllow -band $RequiredValue) -eq $RequiredValue) -and
  $InheritanceMatches -and
  (($ExplicitDeny -band $RequiredValue) -eq 0)
)

$Purged = 0

If (-not $AlreadyCorrect -and $PSCmdlet.ShouldProcess($Path, ('Set {0} for {1}' -f $Rights, $Sid))) {
  # Purge before add. This is what separates the script from win_acl: every explicit entry for the
  # identity goes, including a deny that would otherwise survive an added allow.
  $Purged = $ExplicitCount
  $Acl.PurgeAccessRules($SidObject)

  $Rule = New-Object -TypeName:'System.Security.AccessControl.FileSystemAccessRule' -ArgumentList:@(
    $SidObject, $Rights, $Inheritance, 'None', 'Allow'
  )
  $Acl.AddAccessRule($Rule)

  Set-Acl -Path:$Path -AclObject:$Acl

  # The host is mutated from here, and the verification below can still throw.
  $Ansible.Changed = $True

  # Read the descriptor back. Set-Acl reports nothing about what the filesystem kept, and a
  # descriptor written to a path whose owner refuses the change is a silent no-op.
  $After = Get-Acl -Path:$Path
  $AfterAllow = 0
  $AfterDeny = 0
  ForEach ($Ace In @($After.Access)) {
    $AceSid = ''
    Try {
      $AceSid = [System.String]$Ace.IdentityReference.Translate(
        [System.Security.Principal.SecurityIdentifier]
      ).Value
    } Catch {
      $AceSid = [System.String]$Ace.IdentityReference.Value
    }
    If ($AceSid -ne $Sid) { Continue }
    If ($Ace.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny) {
      $AfterDeny = $AfterDeny -bor [System.Int32]$Ace.FileSystemRights
    } Else {
      $AfterAllow = $AfterAllow -bor [System.Int32]$Ace.FileSystemRights
    }
  }

  If ((($AfterAllow -band $RequiredValue) -ne $RequiredValue) -or (($AfterDeny -band $RequiredValue) -ne 0)) {
    Throw ('The access control list on {0} does not grant {1} to {2} after the write.' -f $Path, $Rights, $Sid)
  }
}

$Result = [PSCustomObject]@{
  changed    = [System.Boolean](-not $AlreadyCorrect)
  check_mode = [System.Boolean]$Ansible.CheckMode
  msg        = If ($AlreadyCorrect) {
    '{0} already holds {1} on {2}' -f $Sid, $Rights, $Path
  } ElseIf ($Ansible.CheckMode) {
    '{0} would be set to hold {1} on {2}' -f $Sid, $Rights, $Path
  } Else {
    '{0} set to hold {1} on {2}, replacing {3} explicit entries' -f $Sid, $Rights, $Path, $Purged
  }
  purged     = [System.Int32]$Purged
  sid        = [System.String]$Sid
}
#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result

If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:4
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #

#endregion --- [ Script ] -------------------------------------------------------------------- #
