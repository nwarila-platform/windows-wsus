#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Reports whether a security identifier effectively holds the named rights on a path.

    .DESCRIPTION
        Written because searching icacls output for the desired allow line is not a proof. A deny
        entry on the same identity leaves that allow line exactly where a text search looks for
        it, the search passes, and Windows still applies the deny first -- so a converge can go
        green while the account it just granted cannot write.

        Three things this does that a text search cannot.

        It compares SECURITY IDENTIFIERS, not display names. icacls prints the localised name and
        offers no SID form, so a name comparison fails against a correct ACL on a non-English
        Windows and, worse, could match a different principal that happens to share a name.

        It reads DENY entries and reports whether any of them intersects the rights asked about.
        Intersection, not equality: a deny of Write alone is enough to break a FullControl grant.

        It separates EXPLICIT from INHERITED. An inherited grant is the parent's to withdraw, so a
        caller that needs to own its access asks for the explicit answer, while a caller that only
        needs the access to exist takes the effective one.

    .PARAMETER DebugLevel
        Three digits: ErrorActionPreference, Set-PSDebug, Set-StrictMode.

    .PARAMETER LogLevel
        Six digits, one per stream: Verbose, Debug, Information, Warning, Error, Fatal.

    .PARAMETER Path
        The filesystem path whose access control list is read.

    .PARAMETER Sid
        The security identifier to report on, in SDDL string form -- 'S-1-5-20' for NETWORK
        SERVICE, 'S-1-5-32-545' for the local Users group. Well-known SIDs are identical on every
        Windows install in every language, which is the point.

    .PARAMETER Rights
        The FileSystemRights being asked about, as the enum's own names -- 'FullControl',
        'ReadAndExecute'. Extra rights beyond these do not fail the answer; missing ones do.

    .EXAMPLE
        Get-AclGrant.ps1 -Path 'F:\WSUS\WsusContent' -Sid 'S-1-5-20' -Rights 'FullControl'

    .OUTPUTS
        One object carrying allow_effective, allow_explicit, changed, check_mode, deny_intersects,
        identities, inheritance and msg.

        allow_effective is true when the allow entries together cover the rights, inherited ones
        included. allow_explicit is true only when the entries written ON this path cover them.
        deny_intersects is true when any deny entry, inherited or not, overlaps the rights at all.
#>

[CmdletBinding()]
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
  $Rights
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

# This reads. Nothing below writes.
$Ansible.Changed = $False

# Parsed once, and every comparison below is bitwise against it. Cast rather than string-matched
# so that 'ReadAndExecute' and 'ReadAndExecute, Synchronize' mean what the enum says they mean.
$Required = [System.Security.AccessControl.FileSystemRights]$Rights

$Acl = Get-Acl -Path:$Path

$AllowExplicit = 0
$AllowInherited = 0
$DenyRights = 0
$Inheritance = ''
$Identities = @()

ForEach ($Ace In @($Acl.Access)) {
  # SID, never the display name. Translate is the supported route from an NTAccount; when the
  # entry already holds a SID -- which is what Windows leaves behind for a deleted principal --
  # Translate is a no-op and the fallback reads it directly. Either way the comparison is against
  # a well-known identifier that does not change with the installed language.
  $AceSid = ''
  Try {
    $AceSid = [System.String]$Ace.IdentityReference.Translate(
      [System.Security.Principal.SecurityIdentifier]
    ).Value
  } Catch {
    $AceSid = [System.String]$Ace.IdentityReference.Value
  }

  If ($AceSid -ne $Sid) { Continue }

  $Identities += [System.String]$Ace.IdentityReference
  $AceRights = [System.Int32]$Ace.FileSystemRights

  If ($Ace.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny) {
    $DenyRights = $DenyRights -bor $AceRights
    Continue
  }

  If ($Ace.IsInherited) {
    $AllowInherited = $AllowInherited -bor $AceRights
  } Else {
    $AllowExplicit = $AllowExplicit -bor $AceRights
    If ([System.String]::IsNullOrEmpty($Inheritance)) {
      $Inheritance = [System.String]$Ace.InheritanceFlags
    }
  }
}

# Coverage, not equality: an entry carrying more than was asked for still grants what was asked
# for. Every allow entry for the identity is combined first, because Windows accumulates them.
$RequiredValue = [System.Int32]$Required
$AllowExplicitCovers = (($AllowExplicit -band $RequiredValue) -eq $RequiredValue)
$AllowEffectiveCovers = ((($AllowExplicit -bor $AllowInherited) -band $RequiredValue) -eq $RequiredValue)

# Intersection, not coverage. A deny of one right inside the set is enough: Windows evaluates deny
# before allow, so the grant is broken by any overlap at all.
$DenyIntersects = (($DenyRights -band $RequiredValue) -ne 0)

$Result = [PSCustomObject]@{
  allow_effective = [System.Boolean]$AllowEffectiveCovers
  allow_explicit  = [System.Boolean]$AllowExplicitCovers
  changed         = [System.Boolean]$False
  check_mode      = [System.Boolean]$Ansible.CheckMode
  deny_intersects = [System.Boolean]$DenyIntersects
  identities      = [System.String[]]$Identities
  inheritance     = [System.String]$Inheritance
  msg             = 'sid {0} on {1}: explicit={2} effective={3} deny={4}' -f @(
    $Sid, $Path, $AllowExplicitCovers, $AllowEffectiveCovers, $DenyIntersects
  )
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
