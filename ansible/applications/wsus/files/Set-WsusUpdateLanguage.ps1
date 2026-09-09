#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Restricts the update languages this WSUS server will accept to a declared set.

    .DESCRIPTION
        A WSUS server installs with AllUpdateLanguagesEnabled true, which means a synchronisation
        pulls metadata and binaries for EVERY language Microsoft publishes. On a server that
        exists to patch one estate that is a large, permanent cost in disk and sync time for
        content nobody will ever approve.

        This restricts the set. It clears AllUpdateLanguagesEnabled and writes the declared
        languages instead, and it does BOTH: clearing the flag alone leaves the previous list in
        place, and writing the list alone leaves the flag overriding it.

        The comparison is order-insensitive and case-insensitive, because the server returns the
        set in its own order and casing. Comparing the raw sequences would report a change on
        every converge and rewrite a configuration that already matched.

        After Save() the configuration is re-read from a FRESH handle and compared again. The
        WSUS configuration object is a client-side cache: setting a property and calling Save()
        updates the local object whether or not the server accepted it, so the only honest proof
        that a value persisted is to ask the server for it again.

    .PARAMETER DebugLevel
        Three digits: ErrorActionPreference, Set-PSDebug, Set-StrictMode.

    .PARAMETER LogLevel
        Six digits, one per stream: Verbose, Debug, Information, Warning, Error, Fatal.

    .PARAMETER Language
        The update languages to enable, as the short codes WSUS itself uses, for example 'en'.
        Compared case-insensitively; at least one is required, because a server with an empty
        language set and the all-languages flag cleared can synchronise nothing at all.

    .EXAMPLE
        Set-WsusUpdateLanguage.ps1 -Language 'en'

    .OUTPUTS
        One object carrying all_languages_enabled, changed, check_mode, languages and msg.

        languages is what the server reports AFTER the write, not what was asked for, so a caller
        reading it sees the configuration that exists rather than the one that was intended.
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
  [System.String[]]
  $Language
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

# The transport seeds Changed true. Nothing has been written yet, and a throw below must not
# report a change this run never made.
$Ansible.Changed = $False

# Normalised once, and every later comparison runs against this form. Sorted so the compare is
# order-insensitive, lowercased so it is case-insensitive, unique so a caller repeating a code
# cannot make a matching configuration look different.
$Desired = @(
  $Language |
    ForEach-Object { ([System.String]$PSItem).Trim().ToLowerInvariant() } |
    Where-Object { $PSItem.Length -gt 0 } |
    Sort-Object -Unique
)

If ($Desired.Count -eq 0) {
  Throw 'No update language survived normalisation; a WSUS server with an empty language set and the all-languages flag cleared can synchronise nothing.'
}

# Get-WsusServer rather than the AdminProxy static, because a cmdlet can be replaced by a spec
# and a static type call cannot -- which is what lets this script be tested off Windows.
$Server = Get-WsusServer

If ($Null -eq $Server) {
  Throw 'Get-WsusServer returned nothing; WSUS post-installation must complete before its configuration can be written.'
}

$Configuration = $Server.GetConfiguration()

$AllEnabledBefore = [System.Boolean]$Configuration.AllUpdateLanguagesEnabled
$CurrentBefore = @(
  @($Configuration.GetEnabledUpdateLanguages()) |
    ForEach-Object { ([System.String]$PSItem).Trim().ToLowerInvariant() } |
    Sort-Object -Unique
)

# Two independent reasons to write. The flag overrides the list, so a server with the right list
# and the flag still set is NOT restricted; and a server with the flag clear but the wrong list is
# restricted to the wrong thing.
$NeedsChange = $AllEnabledBefore -or (
  @(Compare-Object -ReferenceObject $CurrentBefore -DifferenceObject $Desired).Count -gt 0
)

$LanguagesAfter = $CurrentBefore
$AllEnabledAfter = $AllEnabledBefore

If ($NeedsChange -and $PSCmdlet.ShouldProcess('WSUS update languages', ('Restrict to {0}' -f ($Desired -join ', ')))) {
  $Collection = New-Object -TypeName:'System.Collections.Specialized.StringCollection'
  ForEach ($Code In $Desired) {
    $Null = $Collection.Add($Code)
  }

  $Configuration.AllUpdateLanguagesEnabled = $False
  $Configuration.SetEnabledUpdateLanguages($Collection)
  $Configuration.Save()

  # The host is mutated from here. Recorded before the verification below, because a Save() that
  # took and a re-read that then failed is still a changed host.
  $Ansible.Changed = $True

  # A FRESH handle. The object above is a client-side cache: it would report the values just
  # assigned to it whether or not the server kept them.
  $Verify = $Server.GetConfiguration()
  $AllEnabledAfter = [System.Boolean]$Verify.AllUpdateLanguagesEnabled
  $LanguagesAfter = @(
    @($Verify.GetEnabledUpdateLanguages()) |
      ForEach-Object { ([System.String]$PSItem).Trim().ToLowerInvariant() } |
      Sort-Object -Unique
  )

  If ($AllEnabledAfter) {
    Throw 'WSUS still reports AllUpdateLanguagesEnabled after the write; the language restriction did not persist.'
  }

  If (@(Compare-Object -ReferenceObject $LanguagesAfter -DifferenceObject $Desired).Count -gt 0) {
    Throw (
      'WSUS reports enabled languages [{0}] after the write, not the declared [{1}].' -f
      ($LanguagesAfter -join ','), ($Desired -join ',')
    )
  }
} ElseIf ($NeedsChange) {
  # Check mode. The need is real and reported; nothing was written, so nothing is verified.
  $Ansible.Changed = $True
}

$Result = [PSCustomObject]@{
  all_languages_enabled = [System.Boolean]$AllEnabledAfter
  changed               = [System.Boolean]$NeedsChange
  check_mode            = [System.Boolean]$Ansible.CheckMode
  languages             = [System.String[]]$LanguagesAfter
  msg                   = If (-not $NeedsChange) {
    'WSUS already restricts updates to {0}' -f ($Desired -join ', ')
  } ElseIf ($Ansible.CheckMode) {
    'WSUS would be restricted to {0}' -f ($Desired -join ', ')
  } Else {
    'WSUS restricted to {0}' -f ($Desired -join ', ')
  }
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
