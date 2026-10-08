# traceIXM

**traceIXM** is a standalone, read-only PowerShell live-trace utility for **Avaya IX Messaging**.

It follows active IX Messaging Voice Server and DBCOM logs and correlates them into an operator-oriented console similar in spirit to an Avaya Communication Manager `list trace` or Session Manager `traceSM` workflow.

> traceIXM is an independent troubleshooting utility. It is not an Avaya product and does not modify IX Messaging configuration or message data.

## Current release

**Version 1.3.1**  
**PowerShell 5.1+**

### Download

The recommended installation method is the current GitHub Release:

- [Latest Releases](https://github.com/RedTech443/traceIXM/releases/latest)
- [traceIXM v1.3.1 PowerShell script](https://github.com/RedTech443/traceIXM/releases/download/v1.3.1/traceIXM-v1.3.1.ps1)
- [traceIXM v1.3.1 ZIP](https://github.com/RedTech443/traceIXM/releases/download/v1.3.1/traceIXM-v1.3.1.zip)
- [SHA-256 checksums](https://github.com/RedTech443/traceIXM/releases/download/v1.3.1/SHA256SUMS-v1.3.1.txt)

Each release contains a versioned `.ps1`, a ZIP package, and SHA-256 checksums.

## What traceIXM does

The default **Summary** view correlates high-value IX Messaging activity into a readable live trace, including:

- call start, calling number, called number, and caller name
- IXM channel correlation
- mailbox and MbxID correlation
- subscriber mailbox login
- normal menu DTMF
- password/PIN authentication state with digits always hidden
- custom-menu levels and DTMF-driven route transitions
- mailbox greeting activity
- voicemail recording start/end evidence
- too-short recording attempts and re-record retries
- voicemail save confirmation
- message GUID and IXM numeric MessageID
- MWI information
- DBCOM external synchronization evidence
- IXM application-level call end
- final call-result classification
- reconstructed call path

traceIXM is deliberately evidence-based. It does not invent friendly meanings for undocumented menu levels and it does not claim to detect subjective audio quality or "dead air" unless IX Messaging itself logs a supported condition.

## Interactive trace

Run the script with no trace/filter arguments:

```powershell
.\traceIXM.ps1
```

At startup, choose a filter:

```text
 [1] Extension / Mailbox
 [2] Caller ID
 [3] Called Number
 [4] IXM Channel
 [5] SIP Call-ID
 [6] IP Address
 [7] Text match
 [8] Keep current filter
 [9] No Filter - Show All
 [0] Start / continue with no filter
```

Extension, caller-ID, and called-number filtering is session-aware. Once a matching IXM channel is identified, related events on that channel continue to be shown even when the literal number is not repeated on every log line.

### Interactive views and controls

```text
[1] Summary
[2] SIP
[3] Calls

Up / Down       Scroll one line
PageUp/PageDown Scroll one page
Home            Jump to oldest available entries
End             Return to LIVE follow mode
F               Change filter
S               Toggle Summary / SIP
C               Clear displayed/captured history
W               Write filtered capture to ZIP
H               Help
Q               Quit
```

The interactive UI uses a **fixed-header viewport**. The header remains locked while only the trace body scrolls.

When viewing the newest events:

```text
SCROLL: LIVE
```

When reviewing older events, the header shows the visible range, for example:

```text
SCROLL: 42-71/184
```

New log activity continues to be captured while you are scrolled back. The viewport stays anchored until you press **End** to return to live-follow mode.

Pressing **C** clears the displayed/captured event history but preserves the current filter and active call-state correlation.

## Example Summary trace

```text
09:27:56.611 STATUS  CH 4  CALL START         Called=64437  Caller=8609030202  Name="INTLX"  RSN=N  MD=1
09:27:56.881 STATUS  CH 4  GREETING           Playing mailbox greeting  Mailbox=64437
09:28:23     STATUS  CH 4  INMSGSTART         Caller=1(860)9030202  Name=INTLX  MbxID=2899
09:28:34.112 STATUS  CH 4  MESSAGE TOO SHORT  Mailbox=64437  FailedAttempt=1
09:28:53.040 STATUS  CH 4  RE-RECORDING       Mailbox=64437  Retry=1
09:28:53     STATUS  CH 4  INMSGSTART         Caller=1(860)9030202  Name=INTLX  MbxID=2899
...
09:30:xx     STATUS  CH 4  CALLENDED
09:30:xx     STATUS  CH 4  CALL END           Duration=...  Mailbox=64437  Reason=IXM CALLENDED
09:30:xx     STATUS  CH 4  CALL RESULT        NO MESSAGE - TOO SHORT  Mailbox=64437  FailedAttempts=4  Retries=3
```

SIP/RVSIP `BYE` and `CANCEL` remain visible as signaling evidence, but they do **not** finalize the IX Messaging application call. traceIXM waits for IXM's own `CALLENDED` event.

## Call-result classification

traceIXM classifies completed calls using IX Messaging evidence observed for that call.

Possible `CALL RESULT` values include:

- **`VOICEMAIL SAVED`** — IXM logged a successful message add.
- **`NO MESSAGE - TOO SHORT`** — IXM explicitly logged one or more `Message too Short` recording attempts; failed-attempt and retry counts are included.
- **`RECORDING ENDED - NO MESSAGE SAVED`** — a recording started and ended but no successful message save was observed.
- **`RECORDING STARTED - NO MESSAGE SAVED`** — a recording began but the call ended before a normal save sequence was observed.
- **`HUNG UP DURING GREETING`** — IXM logged its explicit greeting-hangup statistic before recording began.
- **`HUNG UP BEFORE RECORDING`** — the call reached a mailbox but no recording session was observed and no more-specific greeting-hangup marker was available.
- **`SUBSCRIBER SESSION`** — the caller successfully logged into a mailbox.
- **`CALL ENDED - OUTCOME UNKNOWN`** — the call was captured but IXM did not provide enough application evidence for a more-specific classification.

### Important call-end behavior

IXM's own `<CMD>CALLENDED</CMD>` event is the authoritative application-level call boundary.

traceIXM intentionally does **not** use these as authoritative call-end markers:

- SIP/RVSIP `BYE`
- SIP/RVSIP `CANCEL`
- Voice Server Event 28 / `ResetChannel`

Observed IX Messaging behavior shows that these can occur while the application session continues through greeting, recording, and re-record states.

## DTMF and password protection

Normal menu DTMF is displayed because it is needed for navigation troubleshooting:

```text
DTMF   Digit=4  Menu="Custom Menu 102 Level1"
ROUTE  Menu 102/Level1 --[4]--> Menu 102/Level8
```

Subscriber password/PIN digits are **always hidden**. There is no option to reveal them.

```text
AUTH      Requesting password  State=405
DTMF      Digits=[HIDDEN]  Context=Password
AUTH      Validating password  State=407
LOGIN OK  Subscriber mailbox login successful  Mailbox=10000  MbxID=91
```

An invalid login is shown as `LOGIN FAILED`. traceIXM also redacts password-bearing native STATUS lines before displaying or writing them.

> IX Messaging's own native STATUS log may contain clear-text password values. traceIXM does not re-emit those values.

## Log sources

traceIXM is log-driven and normally tails the current daily files.

### VServer

```text
X:\UC\logs\VServer\STATUS#YYYYMMDD.Log
X:\UC\logs\VServer\Trace#YYYYMMDD.log
X:\UC\logs\VServer\SIP#YYYYMMDD.log
X:\UC\logs\VServer\RVSIP#YYYYMMDD.log
```

### DBCOM

```text
X:\UC\logs\DBCOM\EEAM_EEAMHELPER#YYYYMMDD.log
X:\UC\logs\DBCOM\EEAM_TSECMGR#YYYYMMDD.log
```

On initial startup, traceIXM begins at EOF so it displays **new activity** rather than replaying the entire day's logs.

## Modes

### Summary

```powershell
.\traceIXM.ps1 -Mode Summary
```

Operator-oriented correlated view with repetitive internal log noise suppressed.

### Status

```powershell
.\traceIXM.ps1 -Mode Status
```

Forensic/raw VServer STATUS view. Password-bearing lines are still redacted.

### Trace

```powershell
.\traceIXM.ps1 -Mode Trace
```

Follows the Voice Server `Trace#YYYYMMDD.log`.

### SIP

```powershell
.\traceIXM.ps1 -Mode SIP
```

Follows SIP and RVSIP log activity.

### DBCOM

```powershell
.\traceIXM.ps1 -Mode DBCOM
```

Follows EEAM helper and TSECMGR database/synchronization logs.

### All

```powershell
.\traceIXM.ps1 -Mode All
```

Displays all supported log sources with minimal suppression.

## Command-line filters

Filter by extension/mailbox:

```powershell
.\traceIXM.ps1 -Extension 10000
```

Caller ID / ANI:

```powershell
.\traceIXM.ps1 -CallerID 8605551212
```

Called number:

```powershell
.\traceIXM.ps1 -Called 10099
```

IXM channel:

```powershell
.\traceIXM.ps1 -Channel 1
```

SIP Call-ID:

```powershell
.\traceIXM.ps1 -SipCallId "example-call-id"
```

IP address:

```powershell
.\traceIXM.ps1 -IpAddress 10.1.30.20
```

Text match:

```powershell
.\traceIXM.ps1 -Match 10005
```

Force interactive mode while using other parameters:

```powershell
.\traceIXM.ps1 -Interactive -SqlEnrichment
```

Force classic/non-interactive output:

```powershell
.\traceIXM.ps1 -NoInteractive
```

Write classic trace output continuously to a file:

```powershell
.\traceIXM.ps1 -OutputPath C:\Temp\traceIXM.txt
```

## Capture ZIP

In interactive mode, press **W** to create a troubleshooting ZIP.

The package contains:

```text
traceIXM.txt
sip.txt
filter.json
sessions.json
```

- `traceIXM.txt` — filtered captured events
- `sip.txt` — matching SIP/RVSIP log evidence
- `filter.json` — active filter, version, and capture metadata
- `sessions.json` — current channel/session correlation state

## Voicemail and external-sync correlation

For a deposited voicemail, traceIXM can correlate a chain such as:

```text
call
  -> mailbox / MbxID
  -> voicemail message GUID
  -> EEAMHELPER MessageAddInternal
  -> numeric IXM MessageID
  -> TSECMGR InternalUpdateSyncStatusOfMessage
  -> SyncStatus / IMAPID / SyncID
```

A populated external `SyncID` is displayed as **`EXT SYNC OK`**.

That means IX Messaging recorded a confirmed external synchronization identifier. traceIXM intentionally does **not** label this `EMAIL DELIVERED`, because final recipient inbox delivery is not established by that record alone.

## Optional SQL enrichment

Mailbox metadata can be loaded once at startup from the IX Messaging SQL Anywhere database using SELECT-only queries:

```powershell
.\traceIXM.ps1 -SqlEnrichment
```

SQL enrichment is optional. The live trace remains log-driven and does not continuously poll the database.

## Read-only design

traceIXM:

- opens IX Messaging logs read-only with file sharing
- does not modify IX Messaging configuration
- does not write to the IX Messaging database
- uses SELECT-only SQL when `-SqlEnrichment` is enabled
- does not require Wireshark, tshark, Python, or packet capture
- does not inject SIP or alter calls

## Installation

### GitHub Release

Download the latest release:

https://github.com/RedTech443/traceIXM/releases/latest

Copy the PowerShell script to the IX Messaging server, for example:

```text
C:\scripts\traceIXM.ps1
```

Then run:

```powershell
cd C:\scripts
.\traceIXM.ps1
```

Run from an elevated PowerShell session if the IX Messaging log directories require elevated access.

### Clone the repository

```bash
git clone https://github.com/RedTech443/traceIXM.git
cd traceIXM
```

## Release publishing

GitHub Releases are automatically built from the version declared in:

```powershell
$script:TraceIxmVersion
```

Each release publishes:

```text
traceIXM-vX.Y.Z.ps1
traceIXM-vX.Y.Z.zip
SHA256SUMS-vX.Y.Z.txt
```

Release notes are generated from the matching version section in `CHANGELOG.md`.

## Known behavior and limitations

- Menu numbers and levels are reported exactly as IX Messaging logs them.
- Friendly menu-action names are not inferred unless independently verified.
- SIP/RVSIP `BYE` and `CANCEL` are signaling evidence only and do not finalize the IXM application call.
- Voice Server Event 28 / `ResetChannel` is not treated as an authoritative call end.
- Some SIP/MWI events do not contain a channel number and may display as `CH --` unless reliable correlation is available.
- SIP view is log-based; traceIXM does not start a packet capture.
- SIP Call-ID and IP filters can match only information present in IX Messaging logs.
- Interactive hotkeys require a normal Windows console. In redirected/remoting hosts where `Console.KeyAvailable` is unavailable, live tracing still works and Ctrl+C remains available.
- The in-memory event history is bounded for long-running sessions.
- DBCOM synchronization may occur asynchronously after the originating call.
- `EXT SYNC OK` confirms IXM synchronization evidence, not final recipient inbox delivery.
- `Status` and `All` modes are intentionally verbose.
- Different IX Messaging releases may use different log wording.

## Version history

See [CHANGELOG.md](CHANGELOG.md).

## Disclaimer

traceIXM is an independent troubleshooting utility for Avaya IX Messaging environments. It is not affiliated with, endorsed by, or supported by Avaya.
