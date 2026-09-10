#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Moves the WSUS content store to the declared root, and refuses the state it cannot repair.

    .DESCRIPTION
        WSUS records where its content lives in three places and they can disagree. The registry
        holds the ROOT under Setup\ContentDir. The server API holds the CACHE, one level below, as
        LocalContentCachePath. IIS holds that same cache again as the physical path of the Content
        virtual directory, which is what actually serves files to clients.

        Only wsusutil movecontent updates all three together, so that is what this runs. It COPIES:
        -skipcopy is deliberately absent, because switching the pointers without moving the bytes
        leaves a server that reports health and serves nothing.

        One state is refused rather than repaired. If the API already names the right cache while
        the registry names somewhere else, the two have been edited apart by hand -- movecontent
        will not reconcile that, and writing the registry directly is unsupported. The script stops
        so an operator can look, instead of guessing.

        Each path is normalised the same way -- trimmed, forward slashes folded to back, trailing
        separators removed -- because the three sources disagree on shape even when they agree on
        meaning. Measured on a converged host: IIS returns 'F:\WSUS\WsusContent\' with a trailing
        separator where the API returns the same path without one. Comparing raw reports a split
        brain that does not exist.

        Start-Process rather than the call operator, because a cmdlet can be replaced by a
        specification and a call operator on a path cannot -- which is what lets the move be tested
        off Windows.

    .PARAMETER DebugLevel
        Three digits: ErrorActionPreference, Set-PSDebug, Set-StrictMode.

    .PARAMETER LogLevel
        Six digits, one per stream: Verbose, Debug, Information, Warning, Error, Fatal.

    .PARAMETER ContentRoot
        The root the content store must live under. The cache WSUS serves from is the WsusContent
        directory beneath it.

    .PARAMETER WsusUtilPath
        The wsusutil.exe that performs the move.

    .PARAMETER MoveLogPath
        Where wsusutil writes its own log for the move. Named rather than derived so a failure can
        be read afterwards by an operator who was not watching the run.

    .OUTPUTS
        One object carrying api_path, changed, check_mode, iis_path, msg and registry_path, each
        reported as it stands AFTER any move.
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
  [ValidatePattern('^[A-Za-z]:\\')]
  [System.String]
  $ContentRoot,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[A-Za-z]:\\')]
  [System.String]
  $WsusUtilPath,

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[A-Za-z]:\\')]
  [System.String]
  $MoveLogPath
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

# The transport seeds Changed true. Nothing is moved yet, and a throw below must not report a
# change this run never made.
$Ansible.Changed = $False

$WantRoot = $ContentRoot.Trim().Replace('/', '\').TrimEnd('\')
$WantCache = '{0}\WsusContent' -f $WantRoot
$SetupKey = 'HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup'

# Normalisation is repeated at each read rather than factored into a helper: the script template
# treats a script as a single process stage and its anatomy check refuses function-shaped logic.
# Each read is tolerated separately, because a missing source is a real state -- a half-installed
# server, a Content virtual directory somebody removed -- and an empty answer lets the comparison
# below name what is wrong instead of reporting only that this script could not look.
$RegistryPath = ''
Try {
  $RegistryRaw = [System.String](Get-ItemPropertyValue -Path:$SetupKey -Name:'ContentDir')
  If (-not [System.String]::IsNullOrWhiteSpace($RegistryRaw)) {
    $RegistryPath = $RegistryRaw.Trim().Replace('/', '\').TrimEnd('\')
  }
} Catch {
  Write-Debug -Message:('Registry ContentDir unreadable: {0}' -f $PSItem.Exception.Message)
}

# The API is REFUSED when it cannot be read, never treated as an empty answer. An empty string
# compares as "not the declared cache", which would read a stopped WSUS service as a content store
# in the wrong place and start copying it -- and would satisfy the split-brain clause below at the
# same time, so the guard would fail open exactly when it matters. The realistic path is a host
# back from a reboot before the services region has run.
$ApiPath = ''
Try {
  $Server = Get-WsusServer
  If ($Null -eq $Server) { Throw 'Get-WsusServer returned nothing.' }
  $ApiRaw = [System.String]$Server.GetConfiguration().LocalContentCachePath
  If ([System.String]::IsNullOrWhiteSpace($ApiRaw)) { Throw 'LocalContentCachePath is empty.' }
  $ApiPath = $ApiRaw.Trim().Replace('/', '\').TrimEnd('\')
} Catch {
  Throw (
    'The WSUS API will not say where its content lives ({0}). Refusing rather than reading that as a content store in the wrong place, which would start a copy. WSUS must be running before its content location can be reconciled.' -f
    $PSItem.Exception.Message
  )
}

# The state movecontent cannot repair. The API already names the right cache while the registry
# names somewhere else, which means the two were edited apart by hand. Moving again would not
# reconcile them and a direct registry write is unsupported, so this stops.
If (($ApiPath -ieq $WantCache) -and ($RegistryPath -ine $WantRoot)) {
  Throw (
    'WSUS records its content inconsistently: the API names {0} but the registry names {1} rather than {2}. Only wsusutil moves all three together and it cannot repair this; re-run WSUS post-installation.' -f
    $ApiPath, $RegistryPath, $WantRoot
  )
}

$NeedsMove = ($ApiPath -ine $WantCache)
$Moved = $False

If ($NeedsMove -and $PSCmdlet.ShouldProcess($WantRoot, 'Move the WSUS content store')) {
  $Move = Start-Process -FilePath:$WsusUtilPath -ArgumentList:@('movecontent', $WantRoot, $MoveLogPath) -NoNewWindow -PassThru -Wait

  # The host is changed from here whatever the exit code says: a partial move has still moved.
  $Ansible.Changed = $True

  If ($Move.ExitCode -ne 0) {
    Throw ('wsusutil movecontent exited {0} moving the content store to {1}. Its log is at {2}.' -f $Move.ExitCode, $WantRoot, $MoveLogPath)
  }

  $Moved = $True
}

# Read all three back. An exit code of zero says the command ran, not that the three records agree,
# and the split brain refused above is exactly what a successful-looking run can leave behind.
$RegistryPath = ''
Try {
  $RegistryRaw = [System.String](Get-ItemPropertyValue -Path:$SetupKey -Name:'ContentDir')
  If (-not [System.String]::IsNullOrWhiteSpace($RegistryRaw)) {
    $RegistryPath = $RegistryRaw.Trim().Replace('/', '\').TrimEnd('\')
  }
} Catch {
  Write-Debug -Message:('Registry ContentDir unreadable after the move: {0}' -f $PSItem.Exception.Message)
}

$ApiPath = ''
Try {
  $Server = Get-WsusServer
  If ($Null -eq $Server) { Throw 'Get-WsusServer returned nothing.' }
  $ApiRaw = [System.String]$Server.GetConfiguration().LocalContentCachePath
  If ([System.String]::IsNullOrWhiteSpace($ApiRaw)) { Throw 'LocalContentCachePath is empty.' }
  $ApiPath = $ApiRaw.Trim().Replace('/', '\').TrimEnd('\')
} Catch {
  Throw ('The WSUS API will not say where its content lives after the move ({0}).' -f $PSItem.Exception.Message)
}

$IisPath = ''
Try {
  Import-Module -Name:'WebAdministration' -ErrorAction:'Stop'
  $VirtualDirectory = Get-Item -Path:'IIS:\Sites\WSUS Administration\Content' -ErrorAction:'Stop'
  If ($Null -ne $VirtualDirectory) {
    $IisRaw = [System.String]$VirtualDirectory.PhysicalPath
    If (-not [System.String]::IsNullOrWhiteSpace($IisRaw)) {
      $IisPath = $IisRaw.Trim().Replace('/', '\').TrimEnd('\')
    }
  }
} Catch {
  Write-Debug -Message:('IIS Content virtual directory unreadable: {0}' -f $PSItem.Exception.Message)
}

# All three against the DECLARATION, not against each other: three records agreeing on the wrong
# path are consistent and still wrong.
#
# Gated on what actually happened, not on CheckMode. Suppression can arrive as an injected -WhatIf
# rather than as a CheckMode flag, and reading CheckMode would then verify records the run
# deliberately did not move -- failing a check-mode run against a host that simply needs work.
If ((-not $NeedsMove) -or $Moved) {
  If (($RegistryPath -ine $WantRoot) -or ($ApiPath -ine $WantCache) -or ($IisPath -ine $WantCache)) {
    Throw (
      'WSUS does not keep its content where declared. Registry {0}, API {1}, IIS {2}; expected root {3} and cache {4}. An empty value means the source did not answer.' -f
      $RegistryPath, $ApiPath, $IisPath, $WantRoot, $WantCache
    )
  }
}

$Result = [PSCustomObject]@{
  api_path      = [System.String]$ApiPath
  changed       = [System.Boolean]$Ansible.Changed
  check_mode    = [System.Boolean]$Ansible.CheckMode
  iis_path      = [System.String]$IisPath
  msg           = 'content root {0}: registry [{1}] api [{2}] iis [{3}]' -f $WantRoot, $RegistryPath, $ApiPath, $IisPath
  registry_path = [System.String]$RegistryPath
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
