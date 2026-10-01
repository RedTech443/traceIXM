#requires -version 5.1
<#
.SYNOPSIS
    Avaya IX Messaging - Live Call Trace

.DESCRIPTION
    Standalone, read-only live trace utility for Avaya IX Messaging.

    This script does NOT modify or depend on IXM-Tools.ps1.

    It follows newly appended data in the active VServer/DBCOM logs and presents
    call/session activity in a console view similar in spirit to a PBX live trace.

    Summary mode is the operator-oriented view. It correlates calls, subscriber
    authentication, DTMF, custom-menu transitions, voicemail storage, MWI, and
    external synchronization while suppressing repetitive internal state noise.

    Status mode remains the forensic/raw VServer view.

    Sources:
      STATUS#YYYYMMDD.Log
      Trace#YYYYMMDD.log
      SIP#YYYYMMDD.log
      RVSIP#YYYYMMDD.log
      DBCOM\EEAM_EEAMHELPER#YYYYMMDD.log
      DBCOM\EEAM_TSECMGR#YYYYMMDD.log

    Optional SQL enrichment loads mailbox metadata once at startup using a
    SQL Anywhere System DSN and SELECT-only queries. The live trace itself is
    log-driven; it does not poll the database continuously.

.NOTES
    PowerShell 5.1+
    Read-only.
    Press Ctrl+C to stop.

.EXAMPLE
    .\IXM-LiveTrace.ps1

.EXAMPLE
    .\IXM-LiveTrace.ps1 -Mode All

.EXAMPLE
    .\IXM-LiveTrace.ps1 -Channel 12

.EXAMPLE
    .\IXM-LiveTrace.ps1 -Match 10004

.EXAMPLE
    .\IXM-LiveTrace.ps1 -SqlEnrichment

.EXAMPLE
    .\IXM-LiveTrace.ps1 -Mode SIP -Match 12040
#>

[CmdletBinding()]
param(
    [ValidateSet('Summary','Status','Trace','SIP','DBCOM','All')]
    [string]$Mode = 'Summary',

    [ValidateRange(0,65535)]
    [int]$Channel = 0,

    [string]$Match = '',

    [string]$Extension = '',

    [string]$CallerID = '',

    [string]$Called = '',

    [string]$SipCallId = '',

    [string]$IpAddress = '',

    [switch]$Interactive,

    [switch]$NoInteractive,

    [switch]$SqlEnrichment,

    [ValidateRange(50,5000)]
    [int]$PollMilliseconds = 250,

    [string]$LogRoot = '',

    [string]$OutputPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:TraceIxmVersion = '1.2.2'

$script:InteractiveMode = $false
$script:InteractiveView = 'Summary'
$script:QuitRequested = $false
$script:UiDirty = $true
$script:LastUiRefresh = [datetime]::MinValue
$script:UiRefreshMilliseconds = 500
$script:LastUiLineCount = 0
$script:CurrentUiLineCount = 0
$script:CaptureStarted = Get-Date
$script:CapturedEvents = New-Object System.Collections.Generic.List[object]
$script:MaxCapturedEvents = 10000
$script:ExtensionFilter = [string]$Extension
$script:CallerIdFilter = [string]$CallerID
$script:CalledFilter = [string]$Called
$script:SipCallIdFilter = [string]$SipCallId
$script:IpAddressFilter = [string]$IpAddress
$script:MatchedChannels = @{}

$script:TailStates = @{}
$script:ChannelStates = @{}
$script:XmlBuffers = @{}
$script:MailboxByNumber = @{}
$script:MailboxById = @{}
$script:RecentIdms = @{}
$script:ThreadChannels = @{}
$script:RecentSummaryEvents = @{}
$script:MessageChannels = @{}
$script:PendingDbSync = $null
$script:InitialScanComplete = $false

function Write-Section {
    param([Parameter(Mandatory)][string]$Text)

    Write-Host ''
    Write-Host ('=' * 92) -ForegroundColor DarkGray
    Write-Host ('  {0}' -f $Text) -ForegroundColor Cyan
    Write-Host ('=' * 92) -ForegroundColor DarkGray
}

function Resolve-IxmVServerLogRoot {
    param([string]$Preferred)

    if (-not [string]::IsNullOrWhiteSpace($Preferred)) {
        if (Test-Path -LiteralPath $Preferred -PathType Container) {
            return (Resolve-Path -LiteralPath $Preferred).Path
        }
        throw "The specified VServer log path does not exist: $Preferred"
    }

    $Candidates = New-Object System.Collections.Generic.List[string]

    foreach ($Drive in @('X','C','D','E','F','G')) {
        $Candidates.Add(('{0}:\UC\logs\VServer' -f $Drive))
    }

    try {
        foreach ($Drive in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
            if ($Drive.Root) {
                $Candidates.Add((Join-Path $Drive.Root 'UC\logs\VServer'))
            }
        }
    }
    catch {
        Write-Verbose ('Unable to enumerate filesystem drives: {0}' -f $_.Exception.Message)
    }

    foreach ($Candidate in @($Candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $Candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $Candidate).Path
        }
    }

    throw 'Unable to locate \UC\logs\VServer. Use -LogRoot to specify the path.'
}

function Get-LiveLogPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateSet('STATUS','Trace','SIP','RVSIP','EEAMHELPER','TSECMGR')][string]$Type
    )

    $DateText = Get-Date -Format 'yyyyMMdd'
    $SearchRoot = $Root

    switch ($Type) {
        'EEAMHELPER' {
            $SearchRoot = Join-Path (Split-Path -Parent $Root) 'DBCOM'
            $Prefix = 'EEAM_EEAMHELPER#{0}' -f $DateText
        }
        'TSECMGR' {
            $SearchRoot = Join-Path (Split-Path -Parent $Root) 'DBCOM'
            $Prefix = 'EEAM_TSECMGR#{0}' -f $DateText
        }
        default {
            $Prefix = '{0}#{1}' -f $Type,$DateText
        }
    }

    if (-not (Test-Path -LiteralPath $SearchRoot -PathType Container)) {
        return $null
    }

    $File = Get-ChildItem -LiteralPath $SearchRoot -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.BaseName -ieq $Prefix -or
            $_.Name -like ($Prefix + '.*')
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $File) {
        return $null
    }

    return $File.FullName
}

function Get-NewLogLines {
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Path
    )

    $Item = Get-Item -LiteralPath $Path -ErrorAction Stop

    if (-not $script:TailStates.ContainsKey($Type) -or
        $script:TailStates[$Type].Path -ne $Path) {

        # On initial startup, begin at EOF so only new activity is displayed.
        # On a date/file rollover after startup, begin at byte zero.
        $StartPosition = if ($script:InitialScanComplete) { 0L } else { [int64]$Item.Length }

        $script:TailStates[$Type] = [pscustomobject]@{
            Path = $Path
            Position = $StartPosition
            Pending = ''
        }

        return @()
    }

    $State = $script:TailStates[$Type]

    if ([int64]$Item.Length -lt [int64]$State.Position) {
        # File was truncated/recreated.
        $State.Position = 0L
        $State.Pending = ''
    }

    if ([int64]$Item.Length -eq [int64]$State.Position) {
        return @()
    }

    $Stream = $null
    $Reader = $null

    try {
        [System.IO.FileShare]$ShareMode = (
            [System.IO.FileShare]::ReadWrite -bor
            [System.IO.FileShare]::Delete
        )

        $Stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            $ShareMode
        )

        [void]$Stream.Seek([int64]$State.Position,[System.IO.SeekOrigin]::Begin)

        $Reader = [System.IO.StreamReader]::new(
            $Stream,
            [System.Text.Encoding]::Default,
            $true,
            4096,
            $true
        )

        $Chunk = $Reader.ReadToEnd()

        # We consumed the bytes through the current EOF. Any final text that
        # does not yet end in CR/LF is retained as Pending and prepended to the
        # next poll. This prevents half-written IXM Trace lines from appearing.
        $State.Position = [int64]$Stream.Length

        $Combined = ([string]$State.Pending) + ([string]$Chunk)
        if ([string]::IsNullOrEmpty($Combined)) {
            return @()
        }

        $Normalized = $Combined.Replace("`r`n","`n").Replace("`r","`n")
        $EndsWithNewLine = $Normalized.EndsWith("`n")
        $Parts = @($Normalized.Split([char]10))

        $Lines = @()

        if ($EndsWithNewLine) {
            $State.Pending = ''
            $Limit = $Parts.Count - 1
        }
        else {
            $State.Pending = [string]$Parts[$Parts.Count - 1]
            $Limit = $Parts.Count - 1
        }

        for ($i = 0; $i -lt $Limit; $i++) {
            $Lines += [string]$Parts[$i]
        }

        return $Lines
    }
    finally {
        if ($null -ne $Reader) { $Reader.Dispose() }
        if ($null -ne $Stream) { $Stream.Dispose() }
    }
}

function Get-LineTimeText {
    param([AllowEmptyString()][string]$Line)

    if ($Line -match '(?<!\d)(?<T>\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?)') {
        return $Matches.T
    }

    return (Get-Date -Format 'HH:mm:ss.fff')
}

function Convert-IxmTimeTextToDateTime {
    param([AllowEmptyString()][string]$TimeText)

    if ([string]::IsNullOrWhiteSpace($TimeText)) {
        return [datetime]::MinValue
    }

    foreach ($Format in @('HH:mm:ss.fff','HH:mm:ss.ff','HH:mm:ss.f','HH:mm:ss')) {
        try {
            $Parsed = [datetime]::ParseExact(
                $TimeText,
                $Format,
                [System.Globalization.CultureInfo]::InvariantCulture
            )

            return (Get-Date).Date.Add($Parsed.TimeOfDay)
        }
        catch {}
    }

    return [datetime]::MinValue
}

function Get-ChannelNumber {
    param([AllowEmptyString()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }

    if ($Line -match '\[CH:\s*(?<Channel>\d+)\]') {
        return [int]$Matches.Channel
    }

    if ($Line -match '<CHAN>(?<Channel>\d+)</CHAN>') {
        return [int]$Matches.Channel
    }

    if ($Line -match '(?i)\bChannel:\s*(?<Channel>\d+)\b') {
        return [int]$Matches.Channel
    }

    return $null
}


function Get-TraceThreadKey {
    param(
        [Parameter(Mandatory)][string]$Source,
        [AllowEmptyString()][string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return ''
    }

    if ($Line -match '\[TID:(?<Thread>[0-9A-Fa-f]+)\]') {
        return ('{0}|TID:{1}' -f $Source,$Matches.Thread.ToUpperInvariant())
    }

    if ($Line -match '\[T:(?<Thread>[0-9A-Fa-f]+)\]') {
        return ('{0}|T:{1}' -f $Source,$Matches.Thread.ToUpperInvariant())
    }

    return ''
}

function Resolve-ChannelByThread {
    param(
        [Parameter(Mandatory)][string]$Source,
        [AllowEmptyString()][string]$Line,
        $ChannelNumber
    )

    $ThreadKey = Get-TraceThreadKey -Source $Source -Line $Line

    if ([string]::IsNullOrWhiteSpace($ThreadKey)) {
        return $ChannelNumber
    }

    if ($null -ne $ChannelNumber) {
        $script:ThreadChannels[$ThreadKey] = [pscustomobject]@{
            Channel = [int]$ChannelNumber
            Seen = Get-Date
        }
        return $ChannelNumber
    }

    if ($script:ThreadChannels.ContainsKey($ThreadKey)) {
        $Entry = $script:ThreadChannels[$ThreadKey]

        if (((Get-Date) - $Entry.Seen).TotalSeconds -le 10) {
            return [int]$Entry.Channel
        }
    }

    return $null
}

function Get-RecentMessageAddChannel {
    $Candidates = @(
        $script:ChannelStates.Values |
            Where-Object {
                $_.LastEvent -eq 'MESSAGE ADD' -and
                ((Get-Date) - $_.LastUpdate).TotalSeconds -le 5
            }
    )

    if ($Candidates.Count -eq 1) {
        return [int]$Candidates[0].Channel
    }

    return $null
}

function Test-RecentSummaryDuplicate {
    param([Parameter(Mandatory)]$Event)

    if ($Mode -ne 'Summary') {
        return $false
    }

    $Signature = '{0}|{1}|{2}|{3}' -f `
        $Event.Source,
        $Event.Channel,
        $Event.Event,
        $Event.Detail

    $Now = Get-Date

    if ($script:RecentSummaryEvents.ContainsKey($Signature)) {
        $Previous = $script:RecentSummaryEvents[$Signature]

        if (($Now - $Previous).TotalSeconds -le 2) {
            $script:RecentSummaryEvents[$Signature] = $Now
            return $true
        }
    }

    $script:RecentSummaryEvents[$Signature] = $Now

    # Small periodic cleanup to keep a long-running trace bounded.
    if ($script:RecentSummaryEvents.Count -gt 500) {
        foreach ($Key in @($script:RecentSummaryEvents.Keys)) {
            if (($Now - $script:RecentSummaryEvents[$Key]).TotalSeconds -gt 15) {
                $script:RecentSummaryEvents.Remove($Key)
            }
        }
    }

    return $false
}

function Get-ChannelState {
    param([Parameter(Mandatory)][int]$ChannelNumber)

    if (-not $script:ChannelStates.ContainsKey($ChannelNumber)) {
        $script:ChannelStates[$ChannelNumber] = [pscustomobject]@{
            Channel = $ChannelNumber
            CallerID = ''
            CallerName = ''
            Called = ''
            Mailbox = ''
            MailboxID = ''
            CallID = ''
            LastEvent = ''
            LastUpdate = Get-Date
            LastStateSignature = ''
            LastStateTime = [datetime]::MinValue
            MessageFile = ''
            IxMessageID = ''
            LastSavedTime = [datetime]::MinValue
            SensitiveInput = $false
            InputContext = ''
            LastDtmfBuffer = ''
            CurrentMenu = ''
            CurrentTuiState = ''
            CallActive = $false
            CallStartTime = [datetime]::MinValue
            CallStartText = ''
            CallPath = @()
            LastMenuDigit = ''
            LastMenuDigitTime = [datetime]::MinValue
            LastStateLogTime = [datetime]::MinValue
        }
    }

    return $script:ChannelStates[$ChannelNumber]
}



function Add-IxmCallPathItem {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Item
    )

    if ([string]::IsNullOrWhiteSpace($Item)) {
        return
    }

    $Existing = @($State.CallPath)

    if ($Existing.Count -gt 0 -and $Existing[$Existing.Count - 1] -eq $Item) {
        return
    }

    $State.CallPath = @($Existing + $Item)
}


function Replace-IxmLastCallPathItem {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Replacement
    )

    $Items = @($State.CallPath)

    if ($Items.Count -eq 0) {
        return $false
    }

    $LastIndex = $Items.Count - 1

    if ($Items[$LastIndex] -ne $Expected) {
        return $false
    }

    $Items[$LastIndex] = $Replacement
    $State.CallPath = @($Items)
    return $true
}

function Get-IxmDisconnectChannel {
    param($ChannelNumber)

    if ($null -ne $ChannelNumber) {
        return [int]$ChannelNumber
    }

    # Channel-less SIP disconnects are only correlated when exactly one
    # traceIXM channel is currently active. Never guess when calls overlap.
    $Active = @(
        $script:ChannelStates.Values |
            Where-Object { $_.CallActive }
    )

    if ($Active.Count -eq 1) {
        return [int]$Active[0].Channel
    }

    return $null
}

function New-IxmCallEndEvents {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Time,
        [Parameter(Mandatory)][int]$ChannelNumber,
        [AllowEmptyString()][string]$Reason,
        [AllowEmptyString()][string]$Raw
    )

    $State = Get-ChannelState -ChannelNumber $ChannelNumber

    if (-not $State.CallActive) {
        return
    }

    $EndTime = Convert-IxmTimeTextToDateTime -TimeText $Time
    if ($EndTime -eq [datetime]::MinValue) {
        $EndTime = Get-Date
    }

    $DurationSeconds = [math]::Round(($EndTime - $State.CallStartTime).TotalSeconds,1)
    if ($DurationSeconds -lt 0) {
        $DurationSeconds = [math]::Round(((Get-Date) - $State.CallStartTime).TotalSeconds,1)
    }

    $EndDetail = 'Duration={0} sec' -f $DurationSeconds
    if ($State.Mailbox) {
        $EndDetail += ('  Mailbox={0}' -f $State.Mailbox)
    }
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $EndDetail += ('  Reason={0}' -f $Reason)
    }

    $PathText = (@($State.CallPath) -join ' | ')

    $EndEvent = New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
        -Event 'CALL END' -Detail $EndDetail -Raw $Raw

    $PathEvent = $null
    if (-not [string]::IsNullOrWhiteSpace($PathText)) {
        $PathEvent = New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
            -Event 'CALL PATH' -Detail $PathText -Raw $Raw
    }

    Reset-IxmCallState -State $State

    if ($Mode -eq 'Summary' -and $null -ne $PathEvent) {
        return @($EndEvent,$PathEvent)
    }

    return $EndEvent
}

function Reset-IxmCallState {
    param([Parameter(Mandatory)]$State)

    $State.CallActive = $false
    $State.CallStartTime = [datetime]::MinValue
    $State.CallStartText = ''
    $State.CallPath = @()
    $State.LastMenuDigit = ''
    $State.LastMenuDigitTime = [datetime]::MinValue
    $State.LastDtmfBuffer = ''
    $State.CurrentMenu = ''
    $State.CurrentTuiState = ''
    $State.SensitiveInput = $false
    $State.InputContext = ''
}

function Format-IxmMenuName {
    param([AllowEmptyString()][string]$Menu)

    if ([string]::IsNullOrWhiteSpace($Menu)) {
        return ''
    }

    if ($Menu -match '(?i)^Custom Menu\s+(?<Menu>\d+)\s+Level(?<Level>\d+)$') {
        return ('Menu {0}/Level{1}' -f $Matches.Menu,$Matches.Level)
    }

    return $Menu
}

function Protect-IxmSensitiveLine {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line,
        $State
    )

    $Safe = [string]$Line

    # Security rule: subscriber password/PIN values are never emitted by
    # traceIXM, even in Status/All forensic modes or -OutputPath files.
    $Safe = $Safe -replace '(?i)(MbxCheckPWD,\s*Password:\s*)[^\s,]+','$1[HIDDEN]'

    if ($null -ne $State -and $State.SensitiveInput) {
        $Safe = $Safe -replace "(?i)(dtmfBuffer\(chan\)\s*=\s*)'[^']*'","\`$1'[HIDDEN]'"
        $Safe = $Safe -replace "(?i)(DtmfBuffer\s*:\s*)\S+","\`$1[HIDDEN]"
        $Safe = $Safe -replace "(?i)(Hangup Buffer:\s*)'[^']*'","\`$1'[HIDDEN]'"
        $Safe = $Safe -replace "(?i)(dtmfs returned:\s*)'[^']*'","\`$1'[HIDDEN]'"
        $Safe = $Safe -replace "(?i)(dtmfs returned:\s*)(?!'\[HIDDEN\]')[0-9A-D#\*]+","\`$1[HIDDEN]"
    }

    return $Safe
}

function Get-DtmfDelta {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$FullBuffer,
        [AllowEmptyString()][string]$PreviousBuffer
    )

    if ([string]::IsNullOrEmpty($FullBuffer)) {
        return ''
    }

    if ([string]::IsNullOrEmpty($PreviousBuffer)) {
        return $FullBuffer
    }

    if ($FullBuffer.StartsWith($PreviousBuffer,[System.StringComparison]::Ordinal)) {
        return $FullBuffer.Substring($PreviousBuffer.Length)
    }

    return $FullBuffer
}

function Get-RecentChannelForMailboxId {
    param(
        [Parameter(Mandatory)][string]$MailboxID,
        [int]$Seconds = 60
    )

    $Candidates = @(
        $script:ChannelStates.Values |
            Where-Object {
                $_.MailboxID -eq $MailboxID -and
                ((Get-Date) - $_.LastUpdate).TotalSeconds -le $Seconds
            } |
            Sort-Object LastUpdate -Descending
    )

    if ($Candidates.Count -gt 0) {
        return [int]$Candidates[0].Channel
    }

    return $null
}

function Get-MessageCorrelation {
    param([Parameter(Mandatory)][string]$MessageID)

    if ($script:MessageChannels.ContainsKey($MessageID)) {
        return $script:MessageChannels[$MessageID]
    }

    return $null
}

function Format-ShortSyncId {
    param([AllowEmptyString()][string]$SyncID)

    if ([string]::IsNullOrWhiteSpace($SyncID)) {
        return ''
    }

    $Value = $SyncID.Trim()

    if ($Value.Length -le 48) {
        return $Value
    }

    return ($Value.Substring(0,48) + '...')
}

function Convert-DbComLineToEvent {
    param(
        [Parameter(Mandatory)][ValidateSet('EEAMHELPER','TSECMGR')][string]$Source,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line
    )

    $Time = Get-LineTimeText -Line $Line

    # TSECMGR may wrap a long Exchange/Graph SyncID to the next physical line.
    if ($Source -eq 'TSECMGR' -and $null -ne $script:PendingDbSync) {
        if ($Line -notmatch '^\s*\d{2}:\d{2}:\d{2}(?:\.\d+)?\s' -and
            $Line -notmatch '^\s*\[TID:' -and
            $Line -match '^\s*AAMk') {

            $Continuation = $Line.Trim()
            $SyncID = $Continuation
            $IMAPUIDS = ''

            if ($Continuation -match '^(?<Sync>AAMk.*),\s*IMAPUIDS:\s*(?<Uid>.*)$') {
                $SyncID = $Matches.Sync.Trim()
                $IMAPUIDS = $Matches.Uid.Trim()
            }
            else {
                $SyncID = $Continuation.TrimEnd(',')
            }

            $Pending = $script:PendingDbSync
            $script:PendingDbSync = $null
            $Correlation = Get-MessageCorrelation -MessageID ([string]$Pending.MessageID)
            $ChannelNumber = if ($null -ne $Correlation) { $Correlation.Channel } else { $null }

            $Detail = 'MsgID={0}  SyncStatus={1}  IMAPID={2}  SyncID={3}' -f `
                $Pending.MessageID,
                $Pending.SyncStatus,
                $Pending.IMAPID,
                (Format-ShortSyncId -SyncID $SyncID)

            if ($IMAPUIDS) {
                $Detail += ('  IMAPUIDS={0}' -f $IMAPUIDS)
            }

            if ($null -ne $Correlation) {
                if ($Correlation.Mailbox) { $Detail += ('  Mailbox={0}' -f $Correlation.Mailbox) }
                if ($Correlation.MessageFile) { $Detail += ('  File={0}' -f $Correlation.MessageFile) }
            }

            return (New-TraceEvent -Source 'DBSYNC' -Time $Time -ChannelNumber $ChannelNumber `
                -Event 'EXT SYNC OK' -Detail $Detail -Raw $Line)
        }

        # A continuation did not arrive. Keep parsing the current line normally.
        $script:PendingDbSync = $null
    }

    if ($Source -eq 'EEAMHELPER') {
        if ($Line -match '\[F:\s*MessageAddInternal\].*?\[M:\s*(?<Mbx>\d+)\]\s*\[FLD:\s*(?<Fld>\d+)\]\s*\[MSG:\s*(?<Msg>\d+)\]\s*Message has been added,\s*retval:\s*(?<Ret>-?\d+)') {
            $MailboxID = [string]$Matches.Mbx
            $MessageID = [string]$Matches.Msg
            $FolderID = [string]$Matches.Fld
            $ReturnCode = [int]$Matches.Ret
            $ChannelNumber = Get-RecentChannelForMailboxId -MailboxID $MailboxID
            $Correlation = $null

            if ($null -ne $ChannelNumber) {
                $State = Get-ChannelState -ChannelNumber $ChannelNumber
                $State.IxMessageID = $MessageID
                $State.LastUpdate = Get-Date

                $Correlation = [pscustomobject]@{
                    Channel = $ChannelNumber
                    Mailbox = $State.Mailbox
                    MailboxID = $MailboxID
                    MessageID = $MessageID
                    MessageFile = $State.MessageFile
                    Added = Get-Date
                }

                $script:MessageChannels[$MessageID] = $Correlation
            }
            else {
                $script:MessageChannels[$MessageID] = [pscustomobject]@{
                    Channel = $null
                    Mailbox = ''
                    MailboxID = $MailboxID
                    MessageID = $MessageID
                    MessageFile = ''
                    Added = Get-Date
                }
            }

            $Detail = 'MailboxID={0}  MsgID={1}  Folder={2}  Return={3}' -f `
                $MailboxID,$MessageID,$FolderID,$ReturnCode

            if ($null -ne $Correlation) {
                if ($Correlation.Mailbox) { $Detail += ('  Mailbox={0}' -f $Correlation.Mailbox) }
                if ($Correlation.MessageFile) { $Detail += ('  File={0}' -f $Correlation.MessageFile) }
            }

            return (New-TraceEvent -Source 'DBCOM' -Time $Time -ChannelNumber $ChannelNumber `
                -Event 'MSG INDEXED' -Detail $Detail -Raw $Line)
        }

        # Explicit SMTP evidence, when present in the DBCOM helper log.
        if ($Line -match '(?i)\bSMTP\b' -and $Line -match '(?i)\b(sent|send|success|delivered|accepted)\b') {
            return (New-TraceEvent -Source 'DBCOM' -Time $Time -ChannelNumber $null `
                -Event 'SMTP' -Detail $Line.Trim() -Raw $Line)
        }

        if ($Line -match '(?i)\bSMTP\b' -and $Line -match '(?i)\b(fail|failed|error|exception|timeout|reject)\b') {
            return (New-TraceEvent -Source 'DBCOM' -Time $Time -ChannelNumber $null `
                -Event 'SMTP FAILED' -Detail $Line.Trim() -Raw $Line)
        }

        return
    }

    # TSECMGR external mailbox synchronization.
    if ($Line -match '\[F:\s*InternalUpdateSyncStatusOfMessage\]\s*\[MSG:\s*(?<Msg>\d+)\]\s*SyncStatus:\s*(?<Status>-?\d+),\s*IMAPID:\s*(?<Imap>-?\d+),\s*SyncID:\s*(?<Rest>.*)$') {
        $MessageID = [string]$Matches.Msg
        $SyncStatus = [int]$Matches.Status
        $ImapID = [string]$Matches.Imap
        $Rest = [string]$Matches.Rest
        $SyncID = ''
        $IMAPUIDS = ''

        if ($Rest -match '^(?<Sync>.*),\s*IMAPUIDS:\s*(?<Uid>.*)$') {
            $SyncID = $Matches.Sync.Trim()
            $IMAPUIDS = $Matches.Uid.Trim()
        }
        else {
            $SyncID = $Rest.Trim()
        }

        $Correlation = Get-MessageCorrelation -MessageID $MessageID
        $ChannelNumber = if ($null -ne $Correlation) { $Correlation.Channel } else { $null }

        # Summary should only show sync records that can be correlated to a
        # voicemail observed by this traceIXM session. DBCOM/All modes retain
        # the complete background synchronization stream.
        if ($Mode -eq 'Summary' -and $null -eq $Correlation) {
            return
        }

        if ([string]::IsNullOrWhiteSpace($SyncID)) {
            $script:PendingDbSync = [pscustomobject]@{
                MessageID = $MessageID
                SyncStatus = $SyncStatus
                IMAPID = $ImapID
                EventTime = Get-Date
            }

            # Do not claim success until IXM supplies a SyncID.
            $Detail = 'MsgID={0}  SyncStatus={1}  IMAPID={2}  SyncID=(not yet populated)' -f `
                $MessageID,$SyncStatus,$ImapID

            if ($null -ne $Correlation) {
                if ($Correlation.Mailbox) { $Detail += ('  Mailbox={0}' -f $Correlation.Mailbox) }
                if ($Correlation.MessageFile) { $Detail += ('  File={0}' -f $Correlation.MessageFile) }
            }

            return (New-TraceEvent -Source 'DBSYNC' -Time $Time -ChannelNumber $ChannelNumber `
                -Event 'SYNC STATUS' -Detail $Detail -Raw $Line)
        }

        $Detail = 'MsgID={0}  SyncStatus={1}  IMAPID={2}  SyncID={3}' -f `
            $MessageID,$SyncStatus,$ImapID,(Format-ShortSyncId -SyncID $SyncID)

        if ($IMAPUIDS) {
            $Detail += ('  IMAPUIDS={0}' -f $IMAPUIDS)
        }

        if ($null -ne $Correlation) {
            if ($Correlation.Mailbox) { $Detail += ('  Mailbox={0}' -f $Correlation.Mailbox) }
            if ($Correlation.MessageFile) { $Detail += ('  File={0}' -f $Correlation.MessageFile) }
        }

        return (New-TraceEvent -Source 'DBSYNC' -Time $Time -ChannelNumber $ChannelNumber `
            -Event 'EXT SYNC OK' -Detail $Detail -Raw $Line)
    }

    # Message-linked sync failures.
    if ($Line -match '\[MSG:\s*(?<Msg>\d+)\]') {
        $MessageID = [string]$Matches.Msg

        if ($Line -match '(?i)sync' -and
            $Line -match '(?i)(fail|failed|error|exception|timeout|reject|denied)') {

            $Correlation = Get-MessageCorrelation -MessageID $MessageID
            $ChannelNumber = if ($null -ne $Correlation) { $Correlation.Channel } else { $null }
            $EventName = if ($Line -match '(?i)\b(graph|microsoft\s*graph|msgraph)\b') {
                'GRAPH FAILED'
            }
            else {
                'SYNC FAILED'
            }

            $Detail = 'MsgID={0}  {1}' -f $MessageID,$Line.Trim()

            if ($null -ne $Correlation) {
                if ($Correlation.Mailbox) { $Detail += ('  Mailbox={0}' -f $Correlation.Mailbox) }
                if ($Correlation.MessageFile) { $Detail += ('  File={0}' -f $Correlation.MessageFile) }
            }

            return (New-TraceEvent -Source 'DBSYNC' -Time $Time -ChannelNumber $ChannelNumber `
                -Event $EventName -Detail $Detail -Raw $Line)
        }
    }

    # Explicit Graph/SMTP success/failure statements, if this IXM build logs them.
    if ($Line -match '(?i)\b(graph|microsoft\s*graph|msgraph)\b') {
        if ($Line -match '(?i)\b(fail|failed|error|exception|timeout|reject|denied)\b') {
            return (New-TraceEvent -Source 'DBSYNC' -Time $Time -ChannelNumber $null `
                -Event 'GRAPH FAILED' -Detail $Line.Trim() -Raw $Line)
        }

        if ($Line -match '(?i)\b(success|succeeded|sent|complete|completed|created)\b') {
            return (New-TraceEvent -Source 'DBSYNC' -Time $Time -ChannelNumber $null `
                -Event 'GRAPH' -Detail $Line.Trim() -Raw $Line)
        }
    }

    if ($Line -match '(?i)\bSMTP\b') {
        if ($Line -match '(?i)\b(fail|failed|error|exception|timeout|reject|denied)\b') {
            return (New-TraceEvent -Source 'DBSYNC' -Time $Time -ChannelNumber $null `
                -Event 'SMTP FAILED' -Detail $Line.Trim() -Raw $Line)
        }

        if ($Line -match '(?i)\b(sent|send|success|succeeded|delivered|accepted)\b') {
            return (New-TraceEvent -Source 'DBSYNC' -Time $Time -ChannelNumber $null `
                -Event 'SMTP' -Detail $Line.Trim() -Raw $Line)
        }
    }

    return
}

function Get-SqlAnywhereSystemDsnNames {
    $Names = New-Object System.Collections.Generic.List[string]

    if (-not (Get-Command Get-OdbcDsn -ErrorAction SilentlyContinue)) {
        return @()
    }

    foreach ($Platform in @('64-bit','32-bit')) {
        try {
            $Dsns = @(Get-OdbcDsn -DsnType System -Platform $Platform -ErrorAction Stop)
            foreach ($Dsn in $Dsns) {
                if ($Dsn.Name) {
                    $Names.Add([string]$Dsn.Name)
                }
            }
        }
        catch {
            Write-Verbose ('ODBC DSN enumeration failed for {0}: {1}' -f $Platform,$_.Exception.Message)
        }
    }

    return @($Names | Select-Object -Unique)
}

function Import-IxmMailboxCache {
    Write-Host 'Loading IX Messaging mailbox metadata from SQL Anywhere (SELECT only)...' -ForegroundColor DarkGray

    $Names = @(Get-SqlAnywhereSystemDsnNames)
    if ($Names.Count -eq 0) {
        Write-Host '  No SQL Anywhere/System ODBC DSNs were found. SQL enrichment disabled.' -ForegroundColor Yellow
        return
    }

    foreach ($Name in $Names) {
        $Connection = $null

        try {
            $Connection = New-Object System.Data.Odbc.OdbcConnection
            $Connection.ConnectionString = ('DSN={0}' -f $Name)
            $Connection.Open()

            # First validate that this is an IX Messaging database.
            $Validate = $Connection.CreateCommand()
            $Validate.CommandText = 'SELECT MBXNUMBER FROM DBA.MAILBOX WHERE 1 = 0'
            [void]$Validate.ExecuteReader().Close()

            $SqlWithId = @"
SELECT
    m.MBXNUMBER,
    m.MBXID,
    m.FIRSTNAME,
    m.LASTNAME,
    f.FGNAME
FROM DBA.MAILBOX m
LEFT JOIN DBA.FGROUP f
    ON m.FGROUPID = f.FGROUPID
WHERE m.MBXNUMBER IS NOT NULL
"@

            $SqlWithoutId = @"
SELECT
    m.MBXNUMBER,
    m.FIRSTNAME,
    m.LASTNAME,
    f.FGNAME
FROM DBA.MAILBOX m
LEFT JOIN DBA.FGROUP f
    ON m.FGROUPID = f.FGROUPID
WHERE m.MBXNUMBER IS NOT NULL
"@

            $Table = New-Object System.Data.DataTable
            $Adapter = $null
            $HasMailboxId = $true

            try {
                $Command = $Connection.CreateCommand()
                $Command.CommandText = $SqlWithId
                $Adapter = New-Object System.Data.Odbc.OdbcDataAdapter $Command
                [void]$Adapter.Fill($Table)
            }
            catch {
                if ($null -ne $Adapter) { $Adapter.Dispose() }
                $Table = New-Object System.Data.DataTable
                $Command = $Connection.CreateCommand()
                $Command.CommandText = $SqlWithoutId
                $Adapter = New-Object System.Data.Odbc.OdbcDataAdapter $Command
                [void]$Adapter.Fill($Table)
                $HasMailboxId = $false
            }
            finally {
                if ($null -ne $Adapter) { $Adapter.Dispose() }
            }

            foreach ($Row in $Table.Rows) {
                $Number = if ($Row.IsNull('MBXNUMBER')) { '' } else { ([string]$Row.MBXNUMBER).Trim() }
                if ([string]::IsNullOrWhiteSpace($Number)) { continue }

                $First = if ($Row.IsNull('FIRSTNAME')) { '' } else { ([string]$Row.FIRSTNAME).Trim() }
                $Last = if ($Row.IsNull('LASTNAME')) { '' } else { ([string]$Row.LASTNAME).Trim() }
                $Group = if ($Row.IsNull('FGNAME')) { '' } else { ([string]$Row.FGNAME).Trim() }
                $MailboxId = ''

                if ($HasMailboxId -and $Table.Columns.Contains('MBXID') -and -not $Row.IsNull('MBXID')) {
                    $MailboxId = ([string]$Row.MBXID).Trim()
                }

                $Object = [pscustomobject]@{
                    Extension = $Number
                    MailboxID = $MailboxId
                    Name = (($First + ' ' + $Last).Trim())
                    FeatureGroup = $Group
                }

                $script:MailboxByNumber[$Number] = $Object

                if (-not [string]::IsNullOrWhiteSpace($MailboxId)) {
                    $script:MailboxById[$MailboxId] = $Object
                }
            }

            Write-Host ('  Loaded {0} mailbox records from DSN {1}.' -f $script:MailboxByNumber.Count,$Name) -ForegroundColor Green
            return
        }
        catch {
            Write-Verbose ('DSN {0} was not usable as an IX Messaging DB: {1}' -f $Name,$_.Exception.Message)
        }
        finally {
            if ($null -ne $Connection) {
                try { $Connection.Close() } catch {}
                try { $Connection.Dispose() } catch {}
            }
        }
    }

    Write-Host '  No System DSN with the IX Messaging DBA.MAILBOX schema was usable. SQL enrichment disabled.' -ForegroundColor Yellow
}

function Get-MailboxDescription {
    param(
        [string]$Mailbox,
        [string]$MailboxID
    )

    $M = $null

    if ($Mailbox -and $script:MailboxByNumber.ContainsKey($Mailbox)) {
        $M = $script:MailboxByNumber[$Mailbox]
    }
    elseif ($MailboxID -and $script:MailboxById.ContainsKey($MailboxID)) {
        $M = $script:MailboxById[$MailboxID]
    }

    if ($null -eq $M) {
        return ''
    }

    $Parts = @()
    if ($M.Name) { $Parts += [string]$M.Name }
    if ($M.FeatureGroup) { $Parts += [string]$M.FeatureGroup }

    if ($Parts.Count -eq 0) {
        return ''
    }

    return (' [{0}]' -f ($Parts -join ' / '))
}


function Remove-IxmIntegrationSuffix {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $Result = $Value.Trim()

    # IX Messaging IDMS values can carry an integration suffix such as:
    #   10099♠1
    # The separator is not always decoded identically on every Windows host,
    # so do not key this only to one Unicode glyph. Strip a trailing
    # non-alphanumeric integration delimiter plus its numeric node suffix.
    #
    # Examples removed:
    #   10099♠1
    #   8602308083♠1
    #
    # Ordinary telephone formatting such as +1, parentheses, hyphens, * and #
    # is deliberately preserved.
    $Result = $Result -replace '[^\p{L}\p{Nd}\(\)\[\]\{\}\+\-\*#]+\d+$',''

    return $Result.Trim()
}

function Get-IdmsPayload {
    param([Parameter(Mandatory)][string]$Line)

    $Result = [pscustomobject]@{
        MD = ''
        Reason = ''
        Called = ''
        Caller = ''
        CallerName = ''
        Signature = ''
    }

    if ($Line -match '<MD>(.*?)</MD>') {
        $Result.MD = ([string]$Matches[1]).Trim()
    }

    if ($Line -match '<RSN>(.*?)</RSN>') {
        $Result.Reason = ([string]$Matches[1]).Trim()
    }

    if ($Line -match '<CALLEDID>(.*?)</CALLEDID>') {
        $Result.Called = Remove-IxmIntegrationSuffix -Value ([string]$Matches[1])
    }

    if ($Line -match '<CALLERID>(.*?)</CALLERID>') {
        $Result.Caller = Remove-IxmIntegrationSuffix -Value ([string]$Matches[1])
    }

    if ($Line -match '<CALLERNAME>(.*?)</CALLERNAME>') {
        $Result.CallerName = (([string]$Matches[1]) -replace '\s+',' ').Trim()    }

    $Result.Signature = '{0}|{1}|{2}|{3}|{4}' -f `
        $Result.MD,
        $Result.Reason,
        $Result.Called,
        $Result.Caller,
        $Result.CallerName

    return $Result
}

function Convert-IdmsLineToEvent {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Time,
        $ChannelNumber,
        [Parameter(Mandatory)][string]$Line
    )

    $Payload = Get-IdmsPayload -Line $Line

    # STATUS [CH:n] is the authoritative summary copy on this IXM system.
    # SIP ComposeIDMS and STATUS [BKG] are duplicate integration records.
    if ($Mode -eq 'Summary' -and ($Source -ne 'STATUS' -or $null -eq $ChannelNumber)) {
        return
    }

    # A channel-bearing STATUS record is the strongest correlation. Remember it
    # briefly so duplicate BKG/SIP copies of the same IDMS message can inherit
    # the channel and be suppressed in Summary mode.
    if ($null -ne $ChannelNumber) {
        $NowIdms = Get-Date

        if ($script:RecentIdms.ContainsKey($Payload.Signature)) {
            $Existing = $script:RecentIdms[$Payload.Signature]

            if (($NowIdms - $Existing.Seen).TotalSeconds -le 3) {
                # Same payload copied again by IXM. Preserve Emitted so the
                # second STATUS copy cannot become a second Summary event.
                $Existing.Channel = [int]$ChannelNumber
                $Existing.Seen = $NowIdms
            }
            else {
                $script:RecentIdms[$Payload.Signature] = [pscustomobject]@{
                    Channel = [int]$ChannelNumber
                    Seen = $NowIdms
                    Emitted = $false
                }
            }
        }
        else {
            $script:RecentIdms[$Payload.Signature] = [pscustomobject]@{
                Channel = [int]$ChannelNumber
                Seen = $NowIdms
                Emitted = $false
            }
        }
    }
    elseif ($script:RecentIdms.ContainsKey($Payload.Signature)) {
        $Recent = $script:RecentIdms[$Payload.Signature]
        if (((Get-Date) - $Recent.Seen).TotalSeconds -le 3) {
            $ChannelNumber = [int]$Recent.Channel
        }
    }

    $DetailParts = @()

    if ($Payload.Called) {
        $DetailParts += ('Called={0}' -f $Payload.Called)
    }

    if ($Payload.Caller) {
        $DetailParts += ('Caller={0}' -f $Payload.Caller)
    }

    if ($Payload.CallerName) {
        $DetailParts += ('Name="{0}"' -f $Payload.CallerName)
    }

    if ($Payload.Reason) {
        $DetailParts += ('RSN={0}' -f $Payload.Reason)
    }

    if ($Payload.MD) {
        $DetailParts += ('MD={0}' -f $Payload.MD)
    }

    $IsCallStart = $false

    if ($null -ne $ChannelNumber) {
        $State = Get-ChannelState -ChannelNumber ([int]$ChannelNumber)

        if ($Payload.Caller) { $State.CallerID = $Payload.Caller }
        if ($Payload.CallerName) { $State.CallerName = $Payload.CallerName }
        if ($Payload.Called) { $State.Called = $Payload.Called }

        if (-not $State.CallActive) {
            $State.CallActive = $true
            $State.CallStartTime = Convert-IxmTimeTextToDateTime -TimeText $Time
            if ($State.CallStartTime -eq [datetime]::MinValue) {
                $State.CallStartTime = Get-Date
            }
            $State.CallStartText = $Time
            $State.CallPath = @()
            $State.LastMenuDigit = ''
            $State.LastMenuDigitTime = [datetime]::MinValue
            $State.CurrentMenu = ''
            $State.LastDtmfBuffer = ''

            $PathStart = '{0} -> {1}' -f $Payload.Caller,$Payload.Called
            Add-IxmCallPathItem -State $State -Item $PathStart
            $IsCallStart = $true
        }

        $State.LastEvent = 'IDMS'
        $State.LastUpdate = Get-Date
    }

    # Collapse repeated copies of the same IDMS payload in Summary mode.
    if ($Mode -eq 'Summary' -and $script:RecentIdms.ContainsKey($Payload.Signature)) {
        $Recent = $script:RecentIdms[$Payload.Signature]

        if ($Recent.Emitted -and ((Get-Date) - $Recent.Seen).TotalSeconds -le 3) {
            return
        }

        $Recent.Emitted = $true
    }

    $EventName = 'IDMS'

    if ($Mode -eq 'Summary' -and $IsCallStart) {
        $EventName = 'CALL START'
    }

    return (New-TraceEvent `
        -Source $Source `
        -Time $Time `
        -ChannelNumber $ChannelNumber `
        -Event $EventName `
        -Detail ($DetailParts -join '  ') `
        -Raw $Line)
}

function New-TraceEvent {
    param(
        [string]$Source,
        [string]$Time,
        $ChannelNumber,
        [string]$Event,
        [string]$Detail,
        [string]$Raw
    )

    return [pscustomobject]@{
        Source = $Source
        Time = $Time
        Channel = $ChannelNumber
        Event = $Event
        Detail = $Detail
        Raw = $Raw
    }
}

function Convert-InMsgXmlToEvent {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Text
    )

    $Command = ''
    $MailboxID = ''
    $ChannelNumber = $null
    $CallerID = ''
    $CallerName = ''
    $Time = Get-LineTimeText -Line $Text

    if ($Text -match '<CMD>(INMSGSTART|INMSGEND)</CMD>') { $Command = $Matches[1] }
    if ($Text -match '<MBXID>(\d+)</MBXID>') { $MailboxID = $Matches[1] }
    if ($Text -match '<CHAN>(\d+)</CHAN>') { $ChannelNumber = [int]$Matches[1] }
    if ($Text -match '<CALLERID>(.*?)</CALLERID>') { $CallerID = $Matches[1].Trim() }
    if ($Text -match '<CALLERIDNAME>(.*?)</CALLERIDNAME>') {
        $CallerName = (($Matches[1] -replace '\s+',' ').Trim())
    }

    if ($Text -match '<TIMESTAMP>(\d{14})</TIMESTAMP>') {
        try {
            $Dt = [datetime]::ParseExact(
                $Matches[1],
                'yyyyMMddHHmmss',
                [System.Globalization.CultureInfo]::InvariantCulture
            )
            $Time = $Dt.ToString('HH:mm:ss')
        }
        catch {}
    }

    if ($null -ne $ChannelNumber) {
        $State = Get-ChannelState -ChannelNumber $ChannelNumber
        if ($CallerID) { $State.CallerID = $CallerID }
        if ($CallerName) { $State.CallerName = $CallerName }
        if ($MailboxID) { $State.MailboxID = $MailboxID }
        $State.LastEvent = $Command
        $State.LastUpdate = Get-Date
    }

    $DetailParts = @()
    if ($CallerID) { $DetailParts += ('Caller={0}' -f $CallerID) }
    if ($CallerName) { $DetailParts += ('Name={0}' -f $CallerName) }
    if ($MailboxID) {
        $Extra = Get-MailboxDescription -Mailbox '' -MailboxID $MailboxID
        $DetailParts += ('MbxID={0}{1}' -f $MailboxID,$Extra)
    }

    return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber -Event $Command -Detail ($DetailParts -join '  ') -Raw $Text)
}

function Convert-LiveLineToEvents {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line
    )

    try {
        if ($Source -eq 'EEAMHELPER' -or $Source -eq 'TSECMGR') {
            return (Convert-DbComLineToEvent -Source $Source -Line $Line)
        }

        # STATUS INMSGSTART / INMSGEND XML can span multiple physical lines.
        if ($script:XmlBuffers.ContainsKey($Source)) {
            $script:XmlBuffers[$Source] = [string]$script:XmlBuffers[$Source] + ' ' + $Line.Trim()

            if ($script:XmlBuffers[$Source] -match '</TIMESTAMP>') {
                $XmlText = [string]$script:XmlBuffers[$Source]
                [void]$script:XmlBuffers.Remove($Source)
                return (Convert-InMsgXmlToEvent -Source $Source -Text $XmlText)
            }

            return
        }

        if ($Line -match '<CMD>INMSG(?:START|END)</CMD>') {
            if ($Line -match '</TIMESTAMP>') {
                return (Convert-InMsgXmlToEvent -Source $Source -Text $Line)
            }

            $script:XmlBuffers[$Source] = [string]$Line
            return
        }

        $Time = Get-LineTimeText -Line $Line
        $ChannelNumber = Get-ChannelNumber -Line $Line
        $ChannelNumber = Resolve-ChannelByThread -Source $Source -Line $Line -ChannelNumber $ChannelNumber
        $State = $null

        if ($null -ne $ChannelNumber) {
            $State = Get-ChannelState -ChannelNumber ([int]$ChannelNumber)
        }

        # Event 28 / ResetChannel is NOT a reliable call-end boundary.
        # IXM can emit it while a subscriber session is still active (for
        # example between prompt/menu operations), so Summary intentionally
        # ignores it. Call end is finalized from a correlated SIP BYE/CANCEL.

        # -----------------------------------------------------------------
        # Subscriber TUI / DTMF
        #
        # STATUS contains the subscriber mailbox-login and custom-menu flow.
        # Normal menu DTMF is shown. Password/PIN DTMF is always hidden.
        # -----------------------------------------------------------------
        if ($Source -eq 'STATUS' -and $null -ne $State) {

            # DTMF buffers are explicitly cleared at call/menu boundaries.
            if ($Line -match '(?i)ClearDTMF Buffer on Channel') {
                $State.LastDtmfBuffer = ''
            }

            # Capture the mailbox selected/resolved during subscriber access.
            if ($Line -match '(?i)Caller MailboxNum:\s*(?<Mailbox>\d+)') {
                $State.Mailbox = [string]$Matches.Mailbox
                $State.LastUpdate = Get-Date
            }

            if ($Line -match '(?i)\[GetmailboxIDFromExtension\].*End,\s*MboxId:\s*(?<MailboxID>\d+)') {
                if ($Matches.MailboxID -ne '0') {
                    $State.MailboxID = [string]$Matches.MailboxID
                    $State.LastUpdate = Get-Date
                }
            }

            # Password states are explicit in STATUS. Enter sensitive mode
            # before any DTMF/password buffer line can be displayed.
            if ($Line -match '(?i)Chan\s*=\s*\d+\s+State\s+(?<TuiState>\d+)\s+Data:\s+Requesting Password') {
                $State.CurrentTuiState = [string]$Matches.TuiState

                if ($State.InputContext -ne 'Password') {
                    $State.LastDtmfBuffer = ''
                }

                $State.SensitiveInput = $true
                $State.InputContext = 'Password'
                $State.LastEvent = 'AUTH'
                $State.LastUpdate = Get-Date

                return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                    -Event 'AUTH' -Detail ('Requesting password  State={0}' -f $State.CurrentTuiState) -Raw '[PASSWORD STATE]')
            }

            if ($Line -match '(?i)Chan\s*=\s*\d+\s+State\s+(?<TuiState>\d+)\s+Data:\s+Validating Password') {
                $State.CurrentTuiState = [string]$Matches.TuiState
                $State.SensitiveInput = $true
                $State.InputContext = 'Password'
                $State.LastEvent = 'AUTH'
                $State.LastUpdate = Get-Date

                return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                    -Event 'AUTH' -Detail ('Validating password  State={0}' -f $State.CurrentTuiState) -Raw '[PASSWORD STATE]')
            }

            # IXM also logs the completed mailbox password explicitly.
            # Summary suppresses the duplicate line. Status/All retain the
            # evidence line but the password value is always redacted.
            if ($Line -match '(?i)MbxCheckPWD,\s*Password:') {
                if ($Mode -eq 'Summary') {
                    return
                }

                $SafeLine = Protect-IxmSensitiveLine -Line $Line -State $State
                return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                    -Event 'RAW' -Detail $SafeLine.Trim() -Raw $SafeLine)
            }

            if ($Line -match '(?i)MbxCheckPWD,\s*EEAM\.MailboxLogon retval:\s*(?<Ret>-?\d+)') {
                $Ret = [int]$Matches.Ret
                $State.SensitiveInput = $false
                $State.InputContext = ''
                $State.LastDtmfBuffer = ''
                $State.LastUpdate = Get-Date

                if ($Ret -eq 0) {
                    $State.LastEvent = 'LOGIN OK'
                    $Detail = 'Subscriber mailbox login successful'
                    if ($State.Mailbox) { $Detail += ('  Mailbox={0}' -f $State.Mailbox) }
                    if ($State.MailboxID) { $Detail += ('  MbxID={0}' -f $State.MailboxID) }

                    if ($State.Mailbox) {
                        Add-IxmCallPathItem -State $State -Item ('Login mailbox {0}' -f $State.Mailbox)
                    }

                    return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                        -Event 'LOGIN OK' -Detail $Detail -Raw $Line)
                }

                $State.LastEvent = 'LOGIN FAILED'
                return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                    -Event 'LOGIN FAILED' -Detail ('MailboxLogon return={0}' -f $Ret) -Raw $Line)
            }

            # The quoted "dtmfs returned" form is the complete IXM buffer.
            # Comparing it with the previous buffer gives us newly-entered
            # digits without duplicating cumulative input.
            if ($Line -match "(?i)dtmfs returned:\s*'(?<Digits>[0-9A-D#\*]*)'") {
                $FullDigits = [string]$Matches.Digits

                # Empty quoted buffers are normal IXM behavior. They are not
                # errors and should not produce an event.
                if ([string]::IsNullOrEmpty($FullDigits)) {
                    return
                }

                $NewDigits = Get-DtmfDelta -FullBuffer $FullDigits -PreviousBuffer $State.LastDtmfBuffer
                $State.LastDtmfBuffer = $FullDigits
                $State.LastUpdate = Get-Date

                if (-not [string]::IsNullOrEmpty($NewDigits)) {
                    $DisplayDigits = $NewDigits

                    if ($State.SensitiveInput) {
                        $DisplayDigits = '[HIDDEN]'
                    }

                    $Label = if ($State.SensitiveInput) {
                        'Digits'
                    }
                    elseif ($NewDigits.Length -eq 1) {
                        'Digit'
                    }
                    else {
                        'Digits'
                    }

                    $Detail = '{0}={1}' -f $Label,$DisplayDigits

                    if ($State.SensitiveInput -and $State.InputContext) {
                        $Detail += ('  Context={0}' -f $State.InputContext)
                    }
                    elseif ($State.CurrentMenu) {
                        $Detail += ('  Menu="{0}"' -f $State.CurrentMenu)
                        $State.LastMenuDigit = $NewDigits
                        $State.LastMenuDigitTime = Get-Date

                        $PrettyMenuForDigit = Format-IxmMenuName -Menu $State.CurrentMenu
                        Add-IxmCallPathItem -State $State -Item ('{0} [{1}]' -f $PrettyMenuForDigit,$NewDigits)
                    }

                    $SafeRaw = if ($State.SensitiveInput) { '[PASSWORD DTMF HIDDEN]' } else { $Line }

                    return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                        -Event 'DTMF' -Detail $Detail -Raw $SafeRaw)
                }

                return
            }

            # Custom-menu context is explicitly logged by the Voice Server.
            # Summary collapses the 100/101/102 state churn for the same menu.
            # When a recent DTMF selection is followed by a different level,
            # emit a CM-style route line showing the actual transition.
            if ($Line -match '(?i)Chan\s*=\s*\d+\s+State\s+(?<TuiState>\d+)\s+Data:\s+(?<Menu>Custom Menu\s+\d+\s+Level\d+)') {
                $NewTuiState = [string]$Matches.TuiState
                $NewMenu = [string]$Matches.Menu
                $OldMenu = [string]$State.CurrentMenu

                $State.CurrentTuiState = $NewTuiState
                $State.LastUpdate = Get-Date

                if ($Mode -eq 'Summary' -and $OldMenu -eq $NewMenu) {
                    return
                }

                $State.CurrentMenu = $NewMenu
                $State.LastDtmfBuffer = ''
                $State.LastEvent = 'MENU'

                $PrettyNew = Format-IxmMenuName -Menu $NewMenu

                if ([string]::IsNullOrWhiteSpace($OldMenu)) {
                    Add-IxmCallPathItem -State $State -Item $PrettyNew

                    return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                        -Event 'MENU' -Detail ('{0}  State={1}' -f $PrettyNew,$NewTuiState) -Raw $Line)
                }

                $PrettyOld = Format-IxmMenuName -Menu $OldMenu
                $CanRoute = (
                    -not [string]::IsNullOrWhiteSpace($State.LastMenuDigit) -and
                    ((Get-Date) - $State.LastMenuDigitTime).TotalSeconds -le 5
                )

                if ($CanRoute) {
                    $RouteDetail = '{0} --[{1}]--> {2}' -f $PrettyOld,$State.LastMenuDigit,$PrettyNew
                    $PendingDigitItem = '{0} [{1}]' -f $PrettyOld,$State.LastMenuDigit

                    if (-not (Replace-IxmLastCallPathItem -State $State -Expected $PendingDigitItem -Replacement $RouteDetail)) {
                        Add-IxmCallPathItem -State $State -Item $RouteDetail
                    }

                    $State.LastMenuDigit = ''
                    $State.LastMenuDigitTime = [datetime]::MinValue

                    return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                        -Event 'ROUTE' -Detail $RouteDetail -Raw $Line)
                }

                Add-IxmCallPathItem -State $State -Item $PrettyNew

                return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                    -Event 'MENU' -Detail ('{0}  State={1}' -f $PrettyNew,$NewTuiState) -Raw $Line)
            }

            # Useful mailbox count summary when subscriber access succeeds.
            if ($Line -match '(?i)Reading Message Count for Mailbox:\s*(?<Mailbox>\d+),FolderID:(?<Folder>\d+),\s*UnreadVoice:\s*(?<Count>\d+)') {
                $State.Mailbox = [string]$Matches.Mailbox
                return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                    -Event 'MSG COUNT' -Detail ('Mailbox={0}  UnreadVoice={1}' -f $Matches.Mailbox,$Matches.Count) -Raw $Line)
            }
        }

        # Mailbox correlation.
        if ($null -ne $State -and $Line -match 'Recording Menu (?:Mailbox|Mbx)\s+(?<Mailbox>\d+)') {
            $State.Mailbox = [string]$Matches.Mailbox
            $State.LastUpdate = Get-Date

            $Extra = Get-MailboxDescription -Mailbox $State.Mailbox -MailboxID $State.MailboxID
            return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                -Event 'RECORDING' -Detail ('Mailbox={0}{1}' -f $State.Mailbox,$Extra) -Raw $Line)
        }

        if ($null -ne $State -and $Line -match 'MbxNo\s*=\s*(?<Mailbox>\d+),\s*MbxID\s*=\s*(?<MailboxID>\d+)') {
            $State.Mailbox = [string]$Matches.Mailbox
            $State.MailboxID = [string]$Matches.MailboxID
            $State.LastUpdate = Get-Date

            $Extra = Get-MailboxDescription -Mailbox $State.Mailbox -MailboxID $State.MailboxID
            return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                -Event 'MAILBOX' -Detail ('Mailbox={0}  MbxID={1}{2}' -f $State.Mailbox,$State.MailboxID,$Extra) -Raw $Line)
        }

        # Message store sequence.
        if ($Line -match '\[F:FastMessageAdd\]\s+start,.*?Channel:\s*(?<Channel>\d+),\s*CallerIDNumber:\s*(?<Caller>.*?),\s*CallerIDName:\s*(?<Name>.*)$') {
            $ChannelNumber = [int]$Matches.Channel
            $State = Get-ChannelState -ChannelNumber $ChannelNumber
            $State.CallerID = [string]$Matches.Caller.Trim()
            $State.CallerName = [string]$Matches.Name.Trim()
            $State.LastEvent = 'MESSAGE ADD'
            $State.LastUpdate = Get-Date

            return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                -Event 'MESSAGE ADD' -Detail ('Caller={0}  Name={1}' -f $State.CallerID,$State.CallerName) -Raw $Line)
        }

        if ($Line -match 'XEEAM_MessageAdd succeeded') {
            $Detail = ''

            # Some successful MessageAdd lines omit [CH:n]. Thread correlation
            # normally restores it. If not, use a channel only when exactly one
            # channel entered MESSAGE ADD in the previous five seconds.
            if ($null -eq $State) {
                $RecentMessageChannel = Get-RecentMessageAddChannel

                if ($null -ne $RecentMessageChannel) {
                    $ChannelNumber = [int]$RecentMessageChannel
                    $State = Get-ChannelState -ChannelNumber $ChannelNumber
                }
            }

            if ($null -ne $State) {
                $Extra = Get-MailboxDescription -Mailbox $State.Mailbox -MailboxID $State.MailboxID
                $Detail = ('Mailbox={0}  Caller={1}{2}' -f $State.Mailbox,$State.CallerID,$Extra)
                $State.LastEvent = 'VOICEMAIL SAVED'
                $State.LastUpdate = Get-Date
                $State.LastSavedTime = $State.LastUpdate
            }

            return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                -Event 'VOICEMAIL SAVED' -Detail $Detail -Raw $Line)
        }

        if ($null -ne $State -and $Line -match 'EEAM\.GetPlayTime\s*=\s*(?<Ms>\d+)') {
            $Seconds = [math]::Round(([int64]$Matches.Ms / 1000.0),1)

            # EEAM.GetPlayTime can appear more than once during a single call,
            # so it is a media timing sample, not by itself proof of the final
            # voicemail recording duration.
            return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                -Event 'EEAM PLAYTIME' -Detail ('{0} sec' -f $Seconds) -Raw $Line)
        }

        if ($null -ne $State -and $Line -match 'msgrec\.FileName\s*=\s*(?<File>[^\s]+)') {
            $State.MessageFile = ([string]$Matches.File).Trim()
            $State.LastUpdate = Get-Date

            return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                -Event 'MESSAGE FILE' -Detail $State.MessageFile -Raw $Line)
        }

        # IDMS contains the high-value call identity fields (called/caller/name).
        # Summary mode parses and de-duplicates the STATUS/BKG/SIP copies.
        if ($Line -match 'IDMS!') {
            return (Convert-IdmsLineToEvent `
                -Source $Source `
                -Time $Time `
                -ChannelNumber $ChannelNumber `
                -Line $Line)
        }

        # SIP / RVSIP: retain useful signaling without dumping every header in Summary.
        if ($Source -eq 'SIP' -or $Source -eq 'RVSIP') {
            $Trimmed = $Line.Trim()

            # SIP logs may contain timestamps/thread prefixes before the request
            # line. Match a real SIP request token rather than requiring column 1.
            if ($Trimmed -match '(?i)(?:^|\s)(?<Method>INVITE|ACK|BYE|CANCEL|REFER|NOTIFY|OPTIONS|PRACK|UPDATE|INFO|REGISTER)\s+(?:sip:|sips:|tel:|\*)') {
                $SipMethod = ([string]$Matches.Method).ToUpperInvariant()

                if (($SipMethod -eq 'BYE' -or $SipMethod -eq 'CANCEL')) {
                    $DisconnectChannel = Get-IxmDisconnectChannel -ChannelNumber $ChannelNumber

                    if ($null -ne $DisconnectChannel) {
                        $EndEvents = New-IxmCallEndEvents `
                            -Source $Source `
                            -Time $Time `
                            -ChannelNumber ([int]$DisconnectChannel) `
                            -Reason $SipMethod `
                            -Raw $Line

                        if ($null -ne $EndEvents) {
                            return $EndEvents
                        }
                    }
                }

                return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                    -Event $SipMethod -Detail $Trimmed -Raw $Line)
            }

            if ($Trimmed -match '^SIP/2\.0\s+(?<Code>\d{3})\s*(?<Reason>.*)$') {
                $Reason = ([string]$Matches.Reason).Trim()

                return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                    -Event ('SIP {0}' -f $Matches.Code) -Detail $Reason -Raw $Line)
            }

            if ($Trimmed -match '^Voice-Message:\s*(?<New>\d+)\s*/\s*(?<Old>\d+)(?:\s*\((?<UrgentNew>\d+)\s*/\s*(?<UrgentOld>\d+)\))?') {
                $MwiDetail = 'New={0}  Old={1}' -f $Matches.New,$Matches.Old

                if ($Matches.UrgentNew -ne '') {
                    $MwiDetail += ('  UrgentNew={0}  UrgentOld={1}' -f $Matches.UrgentNew,$Matches.UrgentOld)
                }

                return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                    -Event 'MWI' -Detail $MwiDetail -Raw $Line)
            }

            if ($Trimmed -match '^(Call-ID|From|To|Diversion|History-Info|P-Asserted-Identity|Remote-Party-ID)\s*:') {
                return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                    -Event 'SIP HDR' -Detail $Trimmed -Raw $Line)
            }

            if ($Mode -eq 'SIP' -or $Mode -eq 'All') {
                return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                    -Event 'RAW' -Detail $Trimmed -Raw $Line)
            }

            return
        }

        # TRACE: show likely call-state transitions in Summary.
        if ($Source -eq 'Trace') {
            $Trimmed = $Line.Trim()

            if ($Trimmed -match '(?i)Actual VoxFile Play Time\s*=\s*(?<Ms>\d+)\s+Millisecs') {
                $Seconds = [math]::Round(([int64]$Matches.Ms / 1000.0),2)

                return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                    -Event 'VOX LENGTH' -Detail ('{0} sec' -f $Seconds) -Raw $Line)
            }

            if ($Trimmed -match '(?i)Actual Message Play Time\s*=\s*(?<Ms>\d+)\s+Millisecs') {
                $Seconds = [math]::Round(([int64]$Matches.Ms / 1000.0),2)

                return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                    -Event 'MESSAGE LENGTH' -Detail ('{0} sec' -f $Seconds) -Raw $Line)
            }

            if ($Trimmed -match '(?i)\bstate\s+(?<State>\d+).*?\breason\s*=\s*[''"](?<Reason>[^''"]+)[''"]') {
                $StateNumber = [string]$Matches.State
                $StateReason = [string]$Matches.Reason
                $Detail = 'State={0}  Reason={1}' -f $StateNumber,$StateReason

                if ($null -ne $State) {
                    $StateSignature = '{0}|{1}' -f $StateNumber,$StateReason
                    $Now = Get-Date
                    $LogTime = Convert-IxmTimeTextToDateTime -TimeText $Time

                    # IXM commonly writes both "Channel1 reason" and
                    # "[state 99], smdi reason" for the same transition. The
                    # second physical log line can be observed much later by a
                    # tailer, so duplicate suppression is based on the LOG
                    # timestamp rather than the time traceIXM received it.
                    if ($Mode -eq 'Summary' -and
                        $State.LastStateSignature -eq $StateSignature -and
                        $LogTime -ne [datetime]::MinValue -and
                        $State.LastStateLogTime -ne [datetime]::MinValue -and
                        [math]::Abs(($LogTime - $State.LastStateLogTime).TotalSeconds) -le 2) {
                        return
                    }

                    $State.LastStateSignature = $StateSignature
                    $State.LastStateTime = $Now
                    $State.LastStateLogTime = $LogTime
                    $State.LastEvent = ('STATE {0}' -f $StateNumber)
                    $State.LastUpdate = $Now
                }

                return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                    -Event 'STATE' -Detail $Detail -Raw $Line)
            }

            if ($Mode -eq 'Summary' -and
                $Trimmed -match '(?i)(?:Channel\d+|smdi)\s+(?:Calling|Called|Type)\s*=') {
                return
            }

            if ($Trimmed -match '(?i)\b(ring|answer|answered|hangup|disconnect|transfer|state|dtmf|digit|prompt|play|stop|smdi|idms|call)\b') {
                return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                    -Event 'TRACE' -Detail $Trimmed -Raw $Line)
            }

            if ($Mode -eq 'Trace' -or $Mode -eq 'All') {
                return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                    -Event 'RAW' -Detail $Trimmed -Raw $Line)
            }

            return
        }

        # STATUS: Summary only shows recognized call events.
        # Raw Status/All retains forensic detail, but password/PIN-bearing
        # fields are always redacted by traceIXM.
        if ($Source -eq 'STATUS' -and ($Mode -eq 'Status' -or $Mode -eq 'All')) {
            $SafeLine = Protect-IxmSensitiveLine -Line $Line -State $State

            return (New-TraceEvent -Source $Source -Time $Time -ChannelNumber $ChannelNumber `
                -Event 'RAW' -Detail $SafeLine.Trim() -Raw $SafeLine)
        }

        return
    }
    catch {
        $ParserLine = $_.InvocationInfo.ScriptLineNumber
        $ParserStatement = $_.InvocationInfo.Line

        if ($ParserStatement) {
            $ParserStatement = $ParserStatement.Trim()
        }

        throw (
            'Live parser failed for source {0} at script line {1}: {2} | Statement: {3}' -f
            $Source,
            $ParserLine,
            $_.Exception.Message,
            $ParserStatement
        )
    }
}


function Clear-IxmInteractiveFilters {
    $script:ExtensionFilter = ''
    $script:CallerIdFilter = ''
    $script:CalledFilter = ''
    $script:SipCallIdFilter = ''
    $script:IpAddressFilter = ''
    $script:MatchedChannels = @{}
}

function Get-IxmFilterDescription {
    $Parts = @()
    if ($Channel -gt 0) { $Parts += ('Channel={0}' -f $Channel) }
    if (-not [string]::IsNullOrWhiteSpace($script:ExtensionFilter)) { $Parts += ('Extension={0}' -f $script:ExtensionFilter) }
    if (-not [string]::IsNullOrWhiteSpace($script:CallerIdFilter)) { $Parts += ('CallerID={0}' -f $script:CallerIdFilter) }
    if (-not [string]::IsNullOrWhiteSpace($script:CalledFilter)) { $Parts += ('Called={0}' -f $script:CalledFilter) }
    if (-not [string]::IsNullOrWhiteSpace($script:SipCallIdFilter)) { $Parts += ('Call-ID={0}' -f $script:SipCallIdFilter) }
    if (-not [string]::IsNullOrWhiteSpace($script:IpAddressFilter)) { $Parts += ('IP={0}' -f $script:IpAddressFilter) }
    if (-not [string]::IsNullOrWhiteSpace($Match)) { $Parts += ('Text={0}' -f $Match) }
    if ($Parts.Count -eq 0) { return '<NO FILTER>' }
    return ($Parts -join '  ')
}

function Show-IxmFilterMenu {
    param([switch]$Startup)

    if (-not $Startup) {
        Write-Host ''
        Write-Host ('=' * 76) -ForegroundColor DarkGray
    }

    Write-Host 'traceIXM Capture Filter' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ' [1] Extension / Mailbox'
    Write-Host ' [2] Caller ID'
    Write-Host ' [3] Called Number'
    Write-Host ' [4] IXM Channel'
    Write-Host ' [5] SIP Call-ID'
    Write-Host ' [6] IP Address'
    Write-Host ' [7] Text match'
    Write-Host ' [8] Keep current filter'
    Write-Host ' [9] No Filter - Show All'
    Write-Host ' [0] Start / continue with no filter'
    Write-Host ''

    $Choice = Read-Host 'Selection'

    switch ($Choice) {
        '1' {
            Clear-IxmInteractiveFilters
            Set-Variable -Name Channel -Scope Script -Value 0
            Set-Variable -Name Match -Scope Script -Value ''
            $script:ExtensionFilter = [string](Read-Host 'Extension / mailbox')
        }
        '2' {
            Clear-IxmInteractiveFilters
            Set-Variable -Name Channel -Scope Script -Value 0
            Set-Variable -Name Match -Scope Script -Value ''
            $script:CallerIdFilter = [string](Read-Host 'Caller ID / ANI')
        }
        '3' {
            Clear-IxmInteractiveFilters
            Set-Variable -Name Channel -Scope Script -Value 0
            Set-Variable -Name Match -Scope Script -Value ''
            $script:CalledFilter = [string](Read-Host 'Called number')
        }
        '4' {
            $Value = Read-Host 'IXM channel'
            if ($Value -match '^\d+$') {
                Clear-IxmInteractiveFilters
                Set-Variable -Name Match -Scope Script -Value ''
                Set-Variable -Name Channel -Scope Script -Value ([int]$Value)
            }
            else {
                Write-Host 'Invalid channel. Existing filter retained.' -ForegroundColor Yellow
            }
        }
        '5' {
            Clear-IxmInteractiveFilters
            Set-Variable -Name Channel -Scope Script -Value 0
            Set-Variable -Name Match -Scope Script -Value ''
            $script:SipCallIdFilter = [string](Read-Host 'SIP Call-ID')
        }
        '6' {
            Clear-IxmInteractiveFilters
            Set-Variable -Name Channel -Scope Script -Value 0
            Set-Variable -Name Match -Scope Script -Value ''
            $script:IpAddressFilter = [string](Read-Host 'IP address')
        }
        '7' {
            Clear-IxmInteractiveFilters
            Set-Variable -Name Channel -Scope Script -Value 0
            Set-Variable -Name Match -Scope Script -Value ([string](Read-Host 'Text to match'))
        }
        '8' { }
        '9' {
            Clear-IxmInteractiveFilters
            Set-Variable -Name Channel -Scope Script -Value 0
            Set-Variable -Name Match -Scope Script -Value ''
        }
        '0' {
            Clear-IxmInteractiveFilters
            Set-Variable -Name Channel -Scope Script -Value 0
            Set-Variable -Name Match -Scope Script -Value ''
        }
        default {
            if ($Startup) {
                Write-Host 'No selection made. Starting with the current filter.' -ForegroundColor Yellow
            }
        }
    }

    Write-Host ('Filter: {0}' -f (Get-IxmFilterDescription)) -ForegroundColor Green
}

function Add-IxmCapturedEvent {
    param([Parameter(Mandatory)]$Event)

    $script:CapturedEvents.Add($Event)
    if ($script:CapturedEvents.Count -gt $script:MaxCapturedEvents) {
        $RemoveCount = [math]::Min(500,($script:CapturedEvents.Count - $script:MaxCapturedEvents))
        $script:CapturedEvents.RemoveRange(0,$RemoveCount)
    }
}

function Format-IxmEventLine {
    param([Parameter(Mandatory)]$Event)

    $ChannelText = if ($null -eq $Event.Channel) { '--' } else { [string]$Event.Channel }
    $Prefix = '{0,-12} {1,-7} CH {2,-4} {3,-18}' -f $Event.Time,$Event.Source,$ChannelText,$Event.Event
    return ('{0} {1}' -f $Prefix,$Event.Detail)
}

function Test-IxmDirectTextMatch {
    param(
        [Parameter(Mandatory)]$Event,
        [Parameter(Mandatory)][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    $Haystack = '{0} {1} {2} {3} {4}' -f $Event.Source,$Event.Channel,$Event.Event,$Event.Detail,$Event.Raw
    return ($Haystack.IndexOf($Value,[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Test-IxmExactNumberMatch {
    param(
        [AllowEmptyString()][string]$Candidate,
        [Parameter(Mandatory)][string]$Wanted
    )

    $CandidateDigits = ($Candidate -replace '[^0-9]','')
    $WantedDigits = ($Wanted -replace '[^0-9]','')

    if ([string]::IsNullOrWhiteSpace($CandidateDigits) -or
        [string]::IsNullOrWhiteSpace($WantedDigits)) {
        return $false
    }

    return ($CandidateDigits -eq $WantedDigits)
}

function Test-IxmEventMatchesFilter {
    param([Parameter(Mandatory)]$Event)

    if ($Channel -gt 0) {
        if ($null -eq $Event.Channel -or [int]$Event.Channel -ne $Channel) { return $false }
    }

    if ($Event.Event -eq 'CALL START' -and $null -ne $Event.Channel) {
        if ($script:MatchedChannels.ContainsKey([int]$Event.Channel)) {
            $script:MatchedChannels.Remove([int]$Event.Channel)
        }
    }

    $NeedsSessionFilter =
        (-not [string]::IsNullOrWhiteSpace($script:ExtensionFilter)) -or
        (-not [string]::IsNullOrWhiteSpace($script:CallerIdFilter)) -or
        (-not [string]::IsNullOrWhiteSpace($script:CalledFilter))

    if ($NeedsSessionFilter) {
        $DirectMatch = $false
        $State = $null

        if ($null -ne $Event.Channel -and $script:MatchedChannels.ContainsKey([int]$Event.Channel)) {
            $DirectMatch = $true
        }

        if ($null -ne $Event.Channel -and $script:ChannelStates.ContainsKey([int]$Event.Channel)) {
            $State = $script:ChannelStates[[int]$Event.Channel]
        }

        if (-not $DirectMatch -and -not [string]::IsNullOrWhiteSpace($script:ExtensionFilter)) {
            $Value = $script:ExtensionFilter

            if ($null -ne $State) {
                foreach ($Candidate in @($State.CallerID,$State.Called,$State.Mailbox)) {
                    if (Test-IxmExactNumberMatch -Candidate ([string]$Candidate) -Wanted $Value) {
                        $DirectMatch = $true
                        break
                    }
                }
            }

            if (-not $DirectMatch -and $Event.Detail -match '(?i)(?:Caller|Called|Mailbox)=(?<Number>[^\s]+)') {
                if (Test-IxmExactNumberMatch -Candidate ([string]$Matches.Number) -Wanted $Value) {
                    $DirectMatch = $true
                }
            }
        }

        if (-not $DirectMatch -and -not [string]::IsNullOrWhiteSpace($script:CallerIdFilter)) {
            $Value = $script:CallerIdFilter

            if ($null -ne $State -and
                (Test-IxmExactNumberMatch -Candidate ([string]$State.CallerID) -Wanted $Value)) {
                $DirectMatch = $true
            }
            elseif ($Event.Detail -match '(?i)Caller=(?<Number>[^\s]+)' -and
                    (Test-IxmExactNumberMatch -Candidate ([string]$Matches.Number) -Wanted $Value)) {
                $DirectMatch = $true
            }
        }

        if (-not $DirectMatch -and -not [string]::IsNullOrWhiteSpace($script:CalledFilter)) {
            $Value = $script:CalledFilter

            if ($null -ne $State -and
                (Test-IxmExactNumberMatch -Candidate ([string]$State.Called) -Wanted $Value)) {
                $DirectMatch = $true
            }
            elseif ($Event.Detail -match '(?i)Called=(?<Number>[^\s]+)' -and
                    (Test-IxmExactNumberMatch -Candidate ([string]$Matches.Number) -Wanted $Value)) {
                $DirectMatch = $true
            }
        }

        if ($DirectMatch -and $null -ne $Event.Channel) {
            $script:MatchedChannels[[int]$Event.Channel] = Get-Date
        }

        if (-not $DirectMatch) { return $false }
    }

    if (-not [string]::IsNullOrWhiteSpace($script:SipCallIdFilter)) {
        if (-not (Test-IxmDirectTextMatch -Event $Event -Value $script:SipCallIdFilter)) { return $false }
    }

    if (-not [string]::IsNullOrWhiteSpace($script:IpAddressFilter)) {
        if (-not (Test-IxmDirectTextMatch -Event $Event -Value $script:IpAddressFilter)) { return $false }
    }

    if (-not [string]::IsNullOrWhiteSpace($Match)) {
        if (-not (Test-IxmDirectTextMatch -Event $Event -Value $Match)) { return $false }
    }

    return $true
}

function Test-IxmViewAllowsEvent {
    param([Parameter(Mandatory)]$Event)

    if (-not $script:InteractiveMode) { return $true }
    if ($script:InteractiveView -eq 'SIP') {
        return ($Event.Source -eq 'SIP' -or $Event.Source -eq 'RVSIP')
    }
    return $true
}

function Get-IxmMatchingCapturedEvents {
    return @(
        $script:CapturedEvents |
            Where-Object { Test-IxmEventMatchesFilter -Event $_ }
    )
}

function Get-IxmConsoleWidth {
    try {
        $Width = [Console]::WindowWidth
        if ($Width -lt 80) { return 80 }
        return $Width
    }
    catch {
        return 120
    }
}

function Get-IxmConsoleHeight {
    try {
        $Height = [Console]::WindowHeight
        if ($Height -lt 24) { return 24 }
        return $Height
    }
    catch {
        return 40
    }
}

function Format-IxmUiText {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$Width
    )

    if ($Width -lt 1) { return '' }
    if ($null -eq $Text) { $Text = '' }

    if ($Text.Length -gt $Width) {
        if ($Width -le 3) { return $Text.Substring(0,$Width) }
        return ($Text.Substring(0,$Width - 3) + '...')
    }

    return $Text.PadRight($Width)
}

function Write-IxmUiLine {
    param(
        [AllowEmptyString()][string]$Text = '',
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    $Width = (Get-IxmConsoleWidth) - 1
    Write-Host (Format-IxmUiText -Text $Text -Width $Width) -ForegroundColor $Color
    $script:CurrentUiLineCount++
}

function Get-IxmActiveCallStates {
    return @(
        $script:ChannelStates.Values |
            Where-Object { $_.CallActive } |
            Sort-Object Channel
    )
}

function Show-IxmInteractiveScreen {
    param([switch]$Force)

    if (-not $script:InteractiveMode) { return }

    $Now = Get-Date
    if (-not $Force -and -not $script:UiDirty -and
        (($Now - $script:LastUiRefresh).TotalMilliseconds -lt $script:UiRefreshMilliseconds)) {
        return
    }

    if (-not $Force -and
        (($Now - $script:LastUiRefresh).TotalMilliseconds -lt $script:UiRefreshMilliseconds)) {
        return
    }

    $script:LastUiRefresh = $Now
    $script:UiDirty = $false

    $Matching = @(Get-IxmMatchingCapturedEvents)
    $ActiveCalls = @(Get-IxmActiveCallStates)
    $SipCount = @($Matching | Where-Object { $_.Source -eq 'SIP' -or $_.Source -eq 'RVSIP' }).Count
    $Height = Get-IxmConsoleHeight

    # Redraw in place instead of Clear-Host. Clearing the console on every
    # refresh causes a visible flash/blink in Windows PowerShell.
    $PreviousLineCount = $script:LastUiLineCount
    $script:CurrentUiLineCount = 0

    try {
        [Console]::CursorVisible = $false
        [Console]::SetCursorPosition(0,0)
    }
    catch {
        # Fall back to normal console output if cursor positioning is not
        # available in the current host.
    }

    Write-IxmUiLine -Text ('traceIXM {0}  |  Avaya IX Messaging Interactive Trace' -f $script:TraceIxmVersion) -Color Cyan
    Write-IxmUiLine -Text ('VIEW: {0,-7}  FILTER: {1}' -f $script:InteractiveView,(Get-IxmFilterDescription)) -Color White
    Write-IxmUiLine -Text ('CAPTURED: {0}   MATCHED: {1}   SIP: {2}   ACTIVE CALLS: {3}   STARTED: {4}' -f
        $script:CapturedEvents.Count,$Matching.Count,$SipCount,$ActiveCalls.Count,$script:CaptureStarted.ToString('HH:mm:ss')) -Color DarkGray
    Write-IxmUiLine -Text ('[1] Summary   [2] SIP   [3] Calls   [F] Filter   [W] Write ZIP   [H] Help   [Q] Quit') -Color Green
    Write-IxmUiLine -Text ('-' * ((Get-IxmConsoleWidth) - 1)) -Color DarkGray

    switch ($script:InteractiveView) {
        'Calls' {
            Write-IxmUiLine -Text ('{0,-5} {1,-16} {2,-16} {3,-14} {4,-8} {5}' -f
                'CH','CALLER','CALLED','MAILBOX','ACTIVE','LAST EVENT') -Color White
            Write-IxmUiLine -Text ('-' * ((Get-IxmConsoleWidth) - 1)) -Color DarkGray

            $States = @($script:ChannelStates.Values | Sort-Object Channel)
            if ($States.Count -eq 0) {
                Write-IxmUiLine -Text 'No call/session state has been observed yet.' -Color DarkGray
            }
            else {
                $MaxRows = [math]::Max(1,$Height - 8)
                foreach ($State in @($States | Select-Object -Last $MaxRows)) {
                    Write-IxmUiLine -Text ('{0,-5} {1,-16} {2,-16} {3,-14} {4,-8} {5}' -f
                        $State.Channel,$State.CallerID,$State.Called,$State.Mailbox,$State.CallActive,$State.LastEvent) -Color Gray
                }
            }
        }

        'SIP' {
            Write-IxmUiLine -Text 'SIP / RVSIP - most recent matching signaling' -Color Cyan
            Write-IxmUiLine -Text ('-' * ((Get-IxmConsoleWidth) - 1)) -Color DarkGray

            $Items = @(
                $Matching |
                    Where-Object { $_.Source -eq 'SIP' -or $_.Source -eq 'RVSIP' }
            )

            if ($Items.Count -eq 0) {
                Write-IxmUiLine -Text 'No matching SIP traffic captured yet.' -Color DarkGray
            }
            else {
                $MaxRows = [math]::Max(1,$Height - 8)
                foreach ($Item in @($Items | Select-Object -Last $MaxRows)) {
                    Write-IxmUiLine -Text (Format-IxmEventLine -Event $Item) -Color Gray
                }
            }
        }

        default {
            Write-IxmUiLine -Text 'SUMMARY - most recent matching correlated events' -Color Cyan
            Write-IxmUiLine -Text ('-' * ((Get-IxmConsoleWidth) - 1)) -Color DarkGray

            if ($Matching.Count -eq 0) {
                Write-IxmUiLine -Text 'Waiting for matching IX Messaging activity...' -Color DarkGray
            }
            else {
                $MaxRows = [math]::Max(1,$Height - 8)
                foreach ($Item in @($Matching | Select-Object -Last $MaxRows)) {
                    Write-IxmUiLine -Text (Format-IxmEventLine -Event $Item) -Color Gray
                }
            }
        }
    }

    # If the new frame is shorter than the previous one, blank the leftover
    # rows so stale lines from the old view do not remain on screen.
    if ($PreviousLineCount -gt $script:CurrentUiLineCount) {
        $Width = (Get-IxmConsoleWidth) - 1
        for ($i = $script:CurrentUiLineCount; $i -lt $PreviousLineCount; $i++) {
            Write-Host (' ' * $Width)
        }
    }

    $script:LastUiLineCount = [math]::Max($script:CurrentUiLineCount,$PreviousLineCount)

    try {
        [Console]::SetCursorPosition(0,[math]::Min($script:CurrentUiLineCount,(Get-IxmConsoleHeight) - 1))
    }
    catch {}
}

function Show-IxmRecentSipTraffic {
    $script:InteractiveView = 'SIP'
    $script:UiDirty = $true
    Show-IxmInteractiveScreen -Force
}

function Show-IxmCallSummary {
    $script:InteractiveView = 'Calls'
    $script:UiDirty = $true
    Show-IxmInteractiveScreen -Force
}

function Export-IxmCapture {
    param([string]$DestinationPath)

    if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
        $BaseFolder = if (Test-Path -LiteralPath 'C:\Temp' -PathType Container) { 'C:\Temp' } else { (Get-Location).Path }
        $DestinationPath = Join-Path $BaseFolder ('traceIXM-{0}.zip' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }

    if (-not $DestinationPath.EndsWith('.zip',[System.StringComparison]::OrdinalIgnoreCase)) {
        $DestinationPath += '.zip'
    }

    $TempFolder = Join-Path ([System.IO.Path]::GetTempPath()) ('traceIXM-{0}' -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $TempFolder -Force | Out-Null

    try {
        $Matching = @($script:CapturedEvents | Where-Object { Test-IxmEventMatchesFilter -Event $_ })
        $SummaryLines = @($Matching | ForEach-Object { Format-IxmEventLine -Event $_ })
        $SipLines = @(
            $Matching |
                Where-Object { $_.Source -eq 'SIP' -or $_.Source -eq 'RVSIP' } |
                ForEach-Object {
                    if (-not [string]::IsNullOrWhiteSpace([string]$_.Raw)) { [string]$_.Raw }
                    else { Format-IxmEventLine -Event $_ }
                }
        )

        Set-Content -LiteralPath (Join-Path $TempFolder 'traceIXM.txt') -Value $SummaryLines -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $TempFolder 'sip.txt') -Value $SipLines -Encoding UTF8

        $FilterInfo = [pscustomobject]@{
            version = $script:TraceIxmVersion
            captureStarted = $script:CaptureStarted
            exported = Get-Date
            filter = Get-IxmFilterDescription
            extension = $script:ExtensionFilter
            callerId = $script:CallerIdFilter
            called = $script:CalledFilter
            channel = $Channel
            sipCallId = $script:SipCallIdFilter
            ipAddress = $script:IpAddressFilter
            text = $Match
        }
        $FilterInfo | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $TempFolder 'filter.json') -Encoding UTF8

        $SessionInfo = @(
            $script:ChannelStates.Values |
                Sort-Object Channel |
                Select-Object Channel,CallerID,CallerName,Called,Mailbox,MailboxID,CallID,CallActive,CallStartText,LastEvent,LastUpdate,CallPath
        )
        $SessionInfo | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $TempFolder 'sessions.json') -Encoding UTF8

        if (Test-Path -LiteralPath $DestinationPath) {
            Remove-Item -LiteralPath $DestinationPath -Force
        }

        Compress-Archive -Path (Join-Path $TempFolder '*') -DestinationPath $DestinationPath -CompressionLevel Optimal
        Write-Host ('Capture written: {0}' -f $DestinationPath) -ForegroundColor Green
        return $DestinationPath
    }
    finally {
        Remove-Item -LiteralPath $TempFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Show-IxmInteractiveHelp {
    Clear-Host
    Write-Host ('traceIXM {0} - Interactive Help' -f $script:TraceIxmVersion) -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Views:' -ForegroundColor White
    Write-Host '  1  Summary - correlated IXM activity'
    Write-Host '  2  SIP     - SIP/RVSIP signaling'
    Write-Host '  3  Calls   - channel/session table'
    Write-Host ''
    Write-Host 'Controls:' -ForegroundColor White
    Write-Host '  F  Change capture filter'
    Write-Host '  S  Toggle Summary / SIP'
    Write-Host '  C  Open Calls view'
    Write-Host '  W  Write current filtered capture to ZIP'
    Write-Host '  H  Show this help'
    Write-Host '  Q  Quit'
    Write-Host ''
    Write-Host 'Press any key to return...' -ForegroundColor DarkGray

    try {
        [void][Console]::ReadKey($true)
    }
    catch {
        [void](Read-Host 'Press ENTER to return')
    }

    $script:UiDirty = $true
    Show-IxmInteractiveScreen -Force
}

function Invoke-IxmInteractiveKeys {
    if (-not $script:InteractiveMode) { return }

    try {
        while ([Console]::KeyAvailable) {
            $Key = [Console]::ReadKey($true)

            switch ($Key.Key) {
                'D1' {
                    $script:InteractiveView = 'Summary'
                    $script:UiDirty = $true
                }
                'NumPad1' {
                    $script:InteractiveView = 'Summary'
                    $script:UiDirty = $true
                }
                'D2' {
                    $script:InteractiveView = 'SIP'
                    $script:UiDirty = $true
                }
                'NumPad2' {
                    $script:InteractiveView = 'SIP'
                    $script:UiDirty = $true
                }
                'D3' {
                    $script:InteractiveView = 'Calls'
                    $script:UiDirty = $true
                }
                'NumPad3' {
                    $script:InteractiveView = 'Calls'
                    $script:UiDirty = $true
                }
                'F' {
                    Clear-Host
                    Show-IxmFilterMenu
                    $script:UiDirty = $true
                    Show-IxmInteractiveScreen -Force
                }
                'S' {
                    if ($script:InteractiveView -eq 'SIP') {
                        $script:InteractiveView = 'Summary'
                    }
                    else {
                        $script:InteractiveView = 'SIP'
                    }
                    $script:UiDirty = $true
                }
                'C' {
                    $script:InteractiveView = 'Calls'
                    $script:UiDirty = $true
                }
                'W' {
                    Clear-Host
                    $Suggested = if (Test-Path -LiteralPath 'C:\Temp' -PathType Container) {
                        Join-Path 'C:\Temp' ('traceIXM-{0}.zip' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                    }
                    else {
                        Join-Path (Get-Location).Path ('traceIXM-{0}.zip' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                    }

                    $Entered = Read-Host ('Capture file [{0}]' -f $Suggested)
                    if ([string]::IsNullOrWhiteSpace($Entered)) { $Entered = $Suggested }
                    [void](Export-IxmCapture -DestinationPath $Entered)
                    $script:UiDirty = $true
                    Start-Sleep -Milliseconds 500
                    Show-IxmInteractiveScreen -Force
                }
                'H' {
                    Show-IxmInteractiveHelp
                }
                'Q' {
                    $script:QuitRequested = $true
                    return
                }
            }
        }
    }
    catch {
        # Redirected/remoting hosts may not expose Console.KeyAvailable.
        # Ctrl+C remains available and the live trace continues.
    }
}

function Test-TraceEventFilter {
    param([Parameter(Mandatory)]$Event)

    if (-not (Test-IxmEventMatchesFilter -Event $Event)) {
        return $false
    }

    if (Test-RecentSummaryDuplicate -Event $Event) {
        return $false
    }

    return $true
}

function Write-TraceEvent {
    param([Parameter(Mandatory)]$Event)

    $Line = Format-IxmEventLine -Event $Event

    $Color = 'Gray'
    switch -Regex ($Event.Event) {
        '^INMSGSTART$'       { $Color = 'Green'; break }
        '^INMSGEND$'         { $Color = 'DarkGreen'; break }
        '^INVITE$'           { $Color = 'Green'; break }
        '^BYE$|^CANCEL$'     { $Color = 'Yellow'; break }
        '^SIP [45]\d\d$'     { $Color = 'Red'; break }
        '^VOICEMAIL SAVED$'  { $Color = 'Cyan'; break }
        '^MESSAGE ADD$'      { $Color = 'Cyan'; break }
        '^IDMS$'             { $Color = 'Magenta'; break }
        '^CALL START$'       { $Color = 'Green'; break }
        '^CALL END$'         { $Color = 'Yellow'; break }
        '^CALL PATH$'        { $Color = 'Cyan'; break }
        '^ROUTE$'            { $Color = 'Magenta'; break }
        '^STATE$'            { $Color = 'Yellow'; break }
        '^MWI$'              { $Color = 'DarkCyan'; break }
        '^DTMF$'             { $Color = 'White'; break }
        '^MENU$'             { $Color = 'Cyan'; break }
        '^AUTH$'             { $Color = 'DarkYellow'; break }
        '^LOGIN OK$'         { $Color = 'Green'; break }
        '^LOGIN FAILED$'     { $Color = 'Red'; break }
        '^MSG COUNT$'        { $Color = 'DarkCyan'; break }
        '^EEAM PLAYTIME$'    { $Color = 'DarkGray'; break }
        '^VOX LENGTH$'       { $Color = 'DarkGray'; break }
        '^MESSAGE LENGTH$'   { $Color = 'Cyan'; break }
        '^MSG INDEXED$'      { $Color = 'DarkCyan'; break }
        '^SYNC STATUS$'      { $Color = 'DarkYellow'; break }
        '^EXT SYNC OK$'      { $Color = 'Green'; break }
        '^GRAPH$|^SMTP$'     { $Color = 'Green'; break }
        '^GRAPH FAILED$|^SMTP FAILED$|^SYNC FAILED$' { $Color = 'Red'; break }
        '^RECORDING$'        { $Color = 'DarkCyan'; break }
        '^RAW$'              { $Color = 'DarkGray'; break }
        default              { $Color = 'Gray' }
    }

    Write-Host $Line -ForegroundColor $Color

    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        try {
            Add-Content -LiteralPath $OutputPath -Value $Line -Encoding UTF8
        }
        catch {
            Write-Verbose ('Unable to append output file: {0}' -f $_.Exception.Message)
        }
    }
}

function Get-EnabledSources {
    switch ($Mode) {
        'Status'  { return @('STATUS') }
        'Trace'   { return @('Trace') }
        'SIP'     { return @('SIP','RVSIP') }
        'DBCOM'   { return @('EEAMHELPER','TSECMGR') }
        'All'     { return @('STATUS','Trace','SIP','RVSIP','EEAMHELPER','TSECMGR') }
        default   { return @('STATUS','Trace','SIP','RVSIP','EEAMHELPER','TSECMGR') }
    }
}

$ResolvedLogRoot = Resolve-IxmVServerLogRoot -Preferred $LogRoot

$HasExplicitTraceArgs =
    $PSBoundParameters.ContainsKey('Mode') -or
    $PSBoundParameters.ContainsKey('Channel') -or
    $PSBoundParameters.ContainsKey('Match') -or
    $PSBoundParameters.ContainsKey('Extension') -or
    $PSBoundParameters.ContainsKey('CallerID') -or
    $PSBoundParameters.ContainsKey('Called') -or
    $PSBoundParameters.ContainsKey('SipCallId') -or
    $PSBoundParameters.ContainsKey('IpAddress') -or
    $PSBoundParameters.ContainsKey('OutputPath')

if ($Interactive) {
    $script:InteractiveMode = $true
}
elseif ($NoInteractive) {
    $script:InteractiveMode = $false
}
else {
    $script:InteractiveMode = -not $HasExplicitTraceArgs
}

if ($script:InteractiveMode) {
    Clear-Host
    Write-Host ('traceIXM {0} - Avaya IX Messaging Interactive Trace' -f $script:TraceIxmVersion) -ForegroundColor Cyan
    Write-Host 'Read-only live trace. Password/PIN digits are always hidden.' -ForegroundColor DarkGray
    Write-Host ''
    Show-IxmFilterMenu -Startup
}

Write-Section 'Avaya IX Messaging - Live Call Trace'
Write-Host ('Version      : {0}' -f $script:TraceIxmVersion)
Write-Host ('VServer logs : {0}' -f $ResolvedLogRoot)
Write-Host ('DBCOM logs   : {0}' -f (Join-Path (Split-Path -Parent $ResolvedLogRoot) 'DBCOM'))
Write-Host ('Mode         : {0}' -f $Mode)
Write-Host ('Filter       : {0}' -f (Get-IxmFilterDescription))
if ($script:InteractiveMode) {
    Write-Host 'Interactive  : 1=Summary  2=SIP  3=Calls  F=Filter  W=Write  H=Help  Q=Quit'
}
if ($Mode -eq 'Summary') {
    Write-Host 'View         : correlated operator trace'
}
elseif ($Mode -eq 'Status') {
    Write-Host 'View         : forensic/raw VServer status'
}
Write-Host ('Channel      : {0}' -f $(if ($Channel -gt 0) { $Channel } else { 'ALL' }))
Write-Host ('Match        : {0}' -f $(if ($Match) { $Match } else { '(none)' }))
Write-Host ('SQL enrich   : {0}' -f $(if ($SqlEnrichment) { 'YES - SELECT only' } else { 'NO' }))
Write-Host ('Poll         : {0} ms' -f $PollMilliseconds)
Write-Host 'Password DTMF: HIDDEN (always)'

if ($OutputPath) {
    Write-Host ('Output file  : {0}' -f $OutputPath)
}

if ($SqlEnrichment) {
    Import-IxmMailboxCache
}

$Sources = @(Get-EnabledSources)

Write-Host ''
Write-Host 'Active source files:' -ForegroundColor Cyan

foreach ($Source in $Sources) {
    $Path = Get-LiveLogPath -Root $ResolvedLogRoot -Type $Source
    if ($Path) {
        Write-Host ('  {0,-11} {1}' -f $Source,$Path) -ForegroundColor DarkGray

        # Initialize at EOF.
        [void](Get-NewLogLines -Type $Source -Path $Path)
    }
    else {
        Write-Host ('  {0,-11} (today''s file not present yet)' -f $Source) -ForegroundColor DarkGray
    }
}

$script:InitialScanComplete = $true

if ($script:InteractiveMode) {
    Show-IxmInteractiveScreen -Force
}
else {
    Write-Host ''
    Write-Host 'Following new activity. Press Ctrl+C to stop.' -ForegroundColor Green
    Write-Host ('{0,-12} {1,-7} {2,-7} {3,-18} {4}' -f 'TIME','SOURCE','CHANNEL','EVENT','DETAIL') -ForegroundColor White
    Write-Host ('-' * 120) -ForegroundColor DarkGray
}

while (-not $script:QuitRequested) {
    foreach ($Source in $Sources) {
        try {
            $Path = Get-LiveLogPath -Root $ResolvedLogRoot -Type $Source
            if (-not $Path) {
                continue
            }

            $Lines = @(Get-NewLogLines -Type $Source -Path $Path)

            foreach ($Line in $Lines) {
                $Events = @(Convert-LiveLineToEvents -Source $Source -Line $Line)

                foreach ($Event in $Events) {
                    Add-IxmCapturedEvent -Event $Event

                    if (Test-TraceEventFilter -Event $Event) {
                        if ($script:InteractiveMode) {
                            $script:UiDirty = $true

                            if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
                                $Line = Format-IxmEventLine -Event $Event
                                Add-Content -LiteralPath $OutputPath -Value $Line -Encoding UTF8
                            }
                        }
                        elseif (Test-IxmViewAllowsEvent -Event $Event) {
                            Write-TraceEvent -Event $Event
                        }
                    }
                }
            }
        }
        catch {
            $ErrLine = $_.InvocationInfo.ScriptLineNumber
            $ErrText = $_.InvocationInfo.Line
            if ($ErrText) { $ErrText = $ErrText.Trim() }

            Write-Host (
                '[{0}] {1}: {2}  [line {3}: {4}]' -f
                (Get-Date -Format 'HH:mm:ss'),
                $Source,
                $_.Exception.Message,
                $ErrLine,
                $ErrText
            ) -ForegroundColor Red
        }
    }

    Invoke-IxmInteractiveKeys
    Show-IxmInteractiveScreen
    Start-Sleep -Milliseconds $PollMilliseconds
}

if ($script:InteractiveMode) {
    Write-Host ''
    Write-Host 'traceIXM stopped.' -ForegroundColor Yellow
}