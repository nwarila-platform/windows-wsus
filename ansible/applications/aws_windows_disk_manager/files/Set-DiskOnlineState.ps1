#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Brings the declared disks online and writable, and reports whether anything moved.

    .DESCRIPTION
        A disk attached to a fresh instance can arrive offline, read-only, or both, and an
        offline disk exposes no partitions -- so every classification step downstream reads
        nothing and concludes the disk is blank. The transitions therefore have to happen
        before any observation the role trusts.

        This replaces an inline win_shell block that split a semicolon-joined string out of an
        environment variable. Two defects came with that form. Identity arrived as text, so a
        drive letter or a stray separator was indistinguishable from a unique id; here the
        caller passes a typed array and the transport marshals it. And a declared id matching no
        attached disk was SILENTLY SKIPPED -- Where-Object returned nothing, the property reads
        against $Null yielded $Null, and the loop moved on reporting no change. A disk the role
        was told to manage and could not find is a fail-closed condition, not a no-op.

        Idempotence is decided by observation, not by the attempt: each transition is applied
        only when the disk is actually in the wrong state, and the result carries the per-disk
        detail so a converge that reports changed can be read back to see which disk moved and
        why. Check mode reports the same decision without writing.

        Org scripts are a single straightforward process stage in the org script template's
        architecture: one [ Script ] region carrying [ Initialization ] (strict mode, transport
        detection, input normalization), [ Main ] (observe -> decide -> apply -> build ONE result
        object), and [ Output ] (the same object to $Ansible or as JSON).

    .PARAMETER DebugLevel
        Three-digit control string configuring independent debugging functions, one digit each.
        First digit: ErrorActionPreference (0 SilentlyContinue, 1 Stop, 2 Continue, 3 Inquire,
        4 Ignore, 5 Suspend). Second digit: Set-PSDebug (0 off, 1 trace 1, 2 trace 2,
        3 trace 1 + step, 4 trace 2 + step). Third digit: Set-StrictMode (0 off, 1-3 that
        version). Default '103': stop on error, no tracing, strict mode 3.

    .PARAMETER LogLevel
        Six-digit control string setting the preference for each stream, in the order Verbose,
        Debug, Information, Warning, Error, Fatal. Each digit is an ActionPreference
        (0 SilentlyContinue, 1 Stop, 2 Continue, 3 Inquire, 4 Ignore, 5 Suspend).

    .PARAMETER UniqueId
        The disk unique ids to bring online and writable. Every entry must resolve to exactly one
        attached disk; anything else fails the run. Order carries no meaning.

    .EXAMPLE
        .\Set-DiskOnlineState.ps1 -UniqueId 'vol0a1b2c3d4e5f6a7b8','vol1122334455667788'

    .OUTPUTS
        One object carrying changed, check_mode, disks, msg and requested.
#>

[CmdletBinding(SupportsShouldProcess)]
[OutputType([System.Void])]
Param (
  [Parameter(
    DontShow = $True,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[0-5]{3}$')]
  [System.String]
  $DebugLevel = '103',

  [Parameter(
    DontShow = $True,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String]
  $LogLevel = '222220',

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidateNotNullOrEmpty()]
  [System.String[]]
  $UniqueId
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

# The module runs this script in check mode because it declares SupportsShouldProcess, and injects
# -WhatIf when it does. This script decides check mode from $Ansible.CheckMode, so -WhatIf is
# neutralised here; left on, it would suppress the New-Variable setup below and the cleanups.
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
  # One diagnostic on one stream, because LogLevel can set any preference to Stop and a
  # diagnostic that throws replaces the failure it exists to describe. The failing source line is
  # appended rather than written separately: a bare `Throw '<string>'` leaves
  # ErrorRecord.InvocationInfo null, so it is read only when it is actually there.
  $Detail = ''
  If (($PSItem.Exception.PSObject.Properties.Name -contains 'ErrorRecord') -and
    ($Null -ne $PSItem.Exception.ErrorRecord) -and
    ($Null -ne $PSItem.Exception.ErrorRecord.InvocationInfo)) {
    $Detail = ' <- {0}' -f [System.String]$PSItem.Exception.ErrorRecord.InvocationInfo.Line.Trim()
  }
  Write-Warning -WarningAction:'Continue' -Message:(
    '[{0:0000}] {1} [{2}]{3}' -f @(
      [System.Int64]$PSItem.InvocationInfo.ScriptLineNumber
      [System.String]$PSItem.Exception.Message
      [System.String]$PSItem.Exception.GetBaseException().GetType().FullName
      $Detail
    )
  )

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

# A repeated id would make the per-disk detail ambiguous and the change count wrong.
$Requested = [System.String[]]@($UniqueId | Where-Object { -not [System.String]::IsNullOrWhiteSpace($_) })
If ($Requested.Count -eq 0) {
  Throw 'UniqueId resolved to no non-empty entries.'
}
$Duplicates = @($Requested | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
If ($Duplicates.Count -gt 0) {
  Throw ('UniqueId carries repeated entries: {0}' -f ($Duplicates -join ', '))
}

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

# ONE enumeration for every declared id. Get-Disk per id would race a disk arriving or leaving
# between calls and would report a state no single moment ever held.
$Attached = @(Get-Disk -ErrorAction:'Stop')

$Changed = $False
$Detail = [System.Collections.Generic.List[PSObject]]::new()

ForEach ($Id In $Requested) {
  $Matched = @($Attached | Where-Object { $_.UniqueId -eq $Id })

  # Fail closed on both directions. Zero means the role was told to manage a disk that is not
  # attached -- the inline predecessor skipped this silently. More than one means identity is
  # not identity, and nothing downstream can be trusted to pick correctly.
  If ($Matched.Count -ne 1) {
    Throw (
      'Expected exactly one attached disk with unique id {0}, found {1}. Attached ids: {2}' -f @(
        $Id
        $Matched.Count
        (($Attached | ForEach-Object { $_.UniqueId }) -join ', ')
      )
    )
  }

  $Disk = $Matched[0]
  $WasReadOnly = [System.Boolean]$Disk.IsReadOnly
  $WasOffline = [System.Boolean]$Disk.IsOffline

  # Read-only is cleared FIRST: an offline read-only disk refuses the online transition, and the
  # reverse order leaves the disk online but unwritable with no error to explain it.
  If ($WasReadOnly) {
    $Changed = $True
    If (-not $Ansible.CheckMode) {
      Set-Disk -Number:$Disk.Number -IsReadOnly:$False -ErrorAction:'Stop'
    }
  }
  If ($WasOffline) {
    $Changed = $True
    If (-not $Ansible.CheckMode) {
      Set-Disk -Number:$Disk.Number -IsOffline:$False -ErrorAction:'Stop'
    }
  }

  # Prove the transitions took. A disk the platform put straight back offline would otherwise
  # report changed on every converge and never converge -- the failure a second-run gate exists
  # to catch, surfaced here instead with the disk that caused it.
  If (($WasReadOnly -or $WasOffline) -and -not $Ansible.CheckMode) {
    $ReRead = @(Get-Disk -Number:$Disk.Number -ErrorAction:'Stop')[0]
    If ($ReRead.IsReadOnly -or $ReRead.IsOffline) {
      Throw (
        'Disk {0} ({1}) read back IsReadOnly={2} IsOffline={3} after the transition.' -f @(
          $Disk.Number, $Id, $ReRead.IsReadOnly, $ReRead.IsOffline
        )
      )
    }
  }

  $Detail.Add([PSCustomObject]@{
      number       = [System.Int32]$Disk.Number
      unique_id    = [System.String]$Id
      was_offline  = $WasOffline
      was_readonly = $WasReadOnly
    })
}

$MovedCount = @($Detail | Where-Object { $_.was_offline -or $_.was_readonly }).Count

$Result = [PSCustomObject]@{
  changed    = [System.Boolean]$Changed
  check_mode = [System.Boolean]$Ansible.CheckMode
  disks      = @($Detail)
  msg        = If ($Changed -and $Ansible.CheckMode) {
    '{0} of {1} declared disk(s) would be brought online and writable' -f $MovedCount, $Requested.Count
  } ElseIf ($Changed) {
    '{0} of {1} declared disk(s) brought online and writable' -f $MovedCount, $Requested.Count
  } Else {
    'all {0} declared disk(s) already online and writable' -f $Requested.Count
  }
  requested  = [System.Int32]$Requested.Count
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
