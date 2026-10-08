# traceIXM

`traceIXM` is a standalone, read-only PowerShell live-trace utility for **Avaya IX Messaging**.

It follows active IX Messaging Voice Server and DBCOM logs and correlates them into a live console view similar in spirit to an Avaya Communication Manager `list trace` session.

> This is an independent troubleshooting utility. It is not an Avaya product and does not modify IX Messaging configuration or data.

## Current version

**1.2.6**

PowerShell **5.1+**.

## What it traces

The default `Summary` view correlates:

- call start / calling / called identity from IDMS
- IXM channel number
- subscriber mailbox login
- live DTMF digits
- password-entry state and validation result (digits always hidden)
- custom voice-menu levels
- DTMF-driven menu transitions
- mailbox / MbxID correlation
- voicemail recording and storage
- message GUID
- IXM numeric message ID
- MWI counts
- external synchronization status from DBCOM
- call end and reconstructed call path

Example operator-style output:

```text
16:49:29.838 STATUS  CH 1  CALL START   Called=10099  Caller=10000  Name="Einstein, Albert"  RSN=N  MD=1
16:49:31.398 STATUS  CH 1  AUTH         Requesting password  State=405
16:49:38.317 STATUS  CH 1  DTMF         Digits=[HIDDEN]  Context=Password
16:49:39.494 STATUS  CH 1  DTMF         Digits=[HIDDEN]  Context=Password
16:49:39.590 STATUS  CH 1  LOGIN OK     Subscriber mailbox login successful  Mailbox=10000  MbxID=91
16:49:39.757 STATUS  CH 1  MENU         Menu 102/Level1  State=103
16:49:59.457 STATUS  CH 1  ROUTE        Menu 102/Level1 --[4]--> Menu 102/Level8
16:50:03.393 STATUS  CH 1  ROUTE        Menu 102/Level8 --[6]--> Menu 102/Level29
...
16:50:20.000 SIP     CH 1  CALL END     Duration=50.2 sec  Mailbox=10000  Reason=BYE
16:50:20.000 SIP     CH 1  CALL PATH    10000 -> 10099 | Login mailbox 10000 | Menu 102/Level1 | Menu 102/Level1 [1] | Menu 102/Level1 --[4]--> Menu 102/Level8 | Menu 102/Level8 --[6]--> Menu 102/Level29
```

The script deliberately does **not** invent friendly labels for undocumented menu levels. A transition such as:

```text
Menu 102/Level1 --[4]--> Menu 102/Level8
```

is reported because that transition is visible in the IX Messaging logs. It is not renamed to a human-friendly action unless the action has been independently verified.

## Log sources

The live trace is log-driven.

VServer:

```text
X:\UC\logs\VServer\STATUS#YYYYMMDD.Log
X:\UC\logs\VServer\Trace#YYYYMMDD.log
X:\UC\logs\VServer\SIP#YYYYMMDD.log
X:\UC\logs\VServer\RVSIP#YYYYMMDD.log
```

DBCOM:

```text
X:\UC\logs\DBCOM\EEAM_EEAMHELPER#YYYYMMDD.log
X:\UC\logs\DBCOM\EEAM_TSECMGR#YYYYMMDD.log
```

`STATUS` is especially valuable for subscriber TUI troubleshooting because IX Messaging records `WaitDTMF`, returned DTMF buffers, password-validation states, mailbox login, and `Custom Menu ... Level...` transitions there.

## Usage

### Interactive trace (default)

Running traceIXM with no trace/filter arguments starts the interactive tracer:

```powershell
.\traceIXM.ps1
```

At startup, choose one of the built-in filters:

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
```

Extension/caller/called filtering is session-aware. Once a matching IXM channel is identified, traceIXM continues showing related TUI/menu activity on that channel even when the literal number is not repeated on every log line.

While the trace is running, the interactive console is a persistent screen instead of a scrolling log:

```text
1  Summary - correlated IXM activity
2  SIP     - SIP/RVSIP signaling
3  Calls   - channel/session table
F  Change filter
S  Toggle Summary / SIP
C  Open Calls view
W  Write the current filtered capture to a ZIP file
H  Show interactive help
Q  Quit
```

The header always shows the active view, current filter, captured/matched counts, SIP count, active-call count, and capture start time. The body automatically uses the available console height for the most recent matching rows.

The SIP view uses IX Messaging's own `SIP#YYYYMMDD.log` and `RVSIP#YYYYMMDD.log`; it does not enable packet capture or modify IXM.

### Command-line / classic mode

Explicit command-line trace arguments retain the traditional scrolling behavior.

Filter by extension/mailbox:

```powershell
.\traceIXM.ps1 -Extension 10000
```

Filter by caller ID / ANI:

```powershell
.\traceIXM.ps1 -CallerID 8605551212
```

Filter by called number:

```powershell
.\traceIXM.ps1 -Called 10099
```

Filter by SIP Call-ID:

```powershell
.\traceIXM.ps1 -SipCallId "example-call-id"
```

Filter by IP address:

```powershell
.\traceIXM.ps1 -IpAddress 10.1.30.20
```

Force the interactive UI while supplying other parameters:

```powershell
.\traceIXM.ps1 -Interactive -SqlEnrichment
```

Force classic/non-interactive behavior:

```powershell
.\traceIXM.ps1 -NoInteractive
```

Trace only one IXM channel:

```powershell
.\traceIXM.ps1 -Channel 1
```

Filter output for a mailbox, extension, number, GUID, or other text:

```powershell
.\traceIXM.ps1 -Match 10005
```

Write the displayed trace continuously to a file:

```powershell
.\traceIXM.ps1 -OutputPath C:\Temp\traceIXM.txt
```

In interactive mode, press `W` to create a troubleshooting ZIP. The ZIP contains:

```text
traceIXM.txt
sip.txt
filter.json
sessions.json
```

`traceIXM.txt` contains the captured events matching the active filter. `sip.txt` contains matching SIP/RVSIP evidence captured from the IX Messaging SIP logs. `filter.json` records the active filter and traceIXM version, and `sessions.json` records the current channel/session correlation state.

Load mailbox metadata once from the IX Messaging SQL Anywhere database using SELECT-only queries:

```powershell
.\traceIXM.ps1 -SqlEnrichment
```

### DTMF / password behavior

Normal menu DTMF is displayed because it is needed to troubleshoot caller navigation:

```text
DTMF  Digit=4  Menu="Custom Menu 102 Level1"
ROUTE Menu 102/Level1 --[4]--> Menu 102/Level8
```

**Subscriber password/PIN digits are always hidden.** There is no command-line option to reveal them.

During password entry the trace shows only the authentication flow:

```text
AUTH         Requesting password  State=405
DTMF         Digits=[HIDDEN]  Context=Password
AUTH         Validating password  State=407
LOGIN OK     Subscriber mailbox login successful  Mailbox=10000  MbxID=91
```

An invalid password is reported as `LOGIN FAILED`. The entered password itself is never written by traceIXM to the console or `-OutputPath`, including in `Status` and `All` modes.

Note: IX Messaging's own native STATUS log may contain the password in clear text; traceIXM redacts it when displaying or copying that line.

## Modes

### Summary

```powershell
.\traceIXM.ps1 -Mode Summary
```

Default operator-oriented view. Correlates useful events and suppresses repetitive internal log noise.

### Status

```powershell
.\traceIXM.ps1 -Mode Status
```

Forensic/raw Voice Server STATUS view. Useful when developing or validating parsers and when a Summary event needs to be traced back to the underlying IXM log evidence.

### Trace

```powershell
.\traceIXM.ps1 -Mode Trace
```

Follows the Voice Server `Trace#YYYYMMDD.log`.

### SIP

```powershell
.\traceIXM.ps1 -Mode SIP
```

Follows SIP and RVSIP activity.

### DBCOM

```powershell
.\traceIXM.ps1 -Mode DBCOM
```

Follows EEAM helper and TSECMGR database/synchronization logs.

### All

```powershell
.\traceIXM.ps1 -Mode All
```

Displays all supported sources with minimal suppression.


## Call outcome classification

traceIXM 1.2.6 classifies each completed call using only IX Messaging events observed for that call. It does **not** claim to detect dead air or subjective audio quality.

Possible `CALL RESULT` values:

- `VOICEMAIL SAVED` — IXM logged a successful message add.
- `RECORDING ENDED - NO MESSAGE SAVED` — recording started and ended, but no successful message add was observed.
- `RECORDING STARTED - NO MESSAGE SAVED` — recording started, but the call ended before a normal end/save sequence was observed.
- `HUNG UP DURING GREETING` — IXM logged its explicit greeting-hangup statistic before recording began.
- `HUNG UP BEFORE RECORDING` — the call reached a mailbox but no recording session was observed and no more specific greeting-hangup marker was available.
- `SUBSCRIBER SESSION` — the caller successfully logged into a mailbox.
- `CALL ENDED - OUTCOME UNKNOWN` — traceIXM captured the call but IXM did not provide enough application evidence for a more specific result.

Example:

```text
08:17:03.120  STATUS  CH 4  CALL START    Called=18728 Caller=7749940426
08:17:07.841  STATUS  CH 4  MAILBOX       Mailbox=18728 MbxID=427
08:17:16.102  SIP     CH 4  CALL END      Duration=13.0 sec Mailbox=18728 Reason=BYE
08:17:16.102  SIP     CH 4  CALL RESULT   HUNG UP BEFORE RECORDING  Mailbox=18728
```

The interactive **Calls** view retains the most recent completed result for each IXM channel until that channel is reused.

## Voicemail / external-sync correlation

For a deposited voicemail, traceIXM can correlate a chain such as:

```text
CALL
  -> mailbox / MbxID
  -> voicemail message file GUID
  -> EEAMHELPER MessageAddInternal
  -> numeric IXM MessageID
  -> TSECMGR InternalUpdateSyncStatusOfMessage
  -> SyncStatus / IMAPID / SyncID
```

A populated external `SyncID` is displayed as `EXT SYNC OK`. This means IX Messaging recorded a confirmed external synchronization identifier; it is intentionally **not** labeled `EMAIL DELIVERED`, because that stronger claim is not established by the synchronization record alone.

## Read-only design

traceIXM:

- opens active log files read-only with file sharing
- starts tailing at EOF so it follows new activity
- does not change IX Messaging configuration
- does not write to the IX Messaging database
- uses only `SELECT` queries when `-SqlEnrichment` is enabled
- does not require Wireshark, tshark, Python, or packet capture

## PowerShell 5.1 compatibility

The script is designed for Windows PowerShell 5.1 and avoids several constructs that caused runtime problems during development:

- ambiguous `New-Object` constructor overloads
- inline enum bitwise expressions inside `FileStream` constructor calls
- generic `List[object]` return paths in the live parser

## Installation

Clone the repository:

```bash
git clone https://github.com/RedTech443/traceIXM.git
cd traceIXM
```

On the IX Messaging Windows server, copy `traceIXM.ps1` to a suitable location, for example:

```text
C:\scripts\traceIXM.ps1
```

Run from an elevated PowerShell session if access to the IX Messaging log directories requires it.

## Updating

From a cloned repository:

```bash
git pull origin main
```

Then replace the Windows copy of `traceIXM.ps1` with the updated file.

## Known behavior / limitations

- Menu numbers and levels are reported exactly as IX Messaging logs them.
- `CALL END` is finalized only from a correlated SIP `BYE`/`CANCEL`; Voice Server Event 28 is intentionally ignored because it can occur mid-session.
- Friendly menu-action names are not inferred.
- Some SIP/MWI events do not contain a channel number and are therefore displayed as `CH --` unless reliable correlation is available.
- SIP view is log-based; version 1.2.0 does not start Wireshark/tshark or create a network PCAP.
- SIP Call-ID and IP filters can only match information actually present in the IX Messaging SIP/RVSIP log lines.
- Interactive hotkeys require a normal Windows console. In redirected/remoting hosts where `Console.KeyAvailable` is unavailable, live tracing still works and Ctrl+C remains available.
- DBCOM synchronization may occur asynchronously after the originating call.
- `EXT SYNC OK` confirms the IXM synchronization record, not final recipient inbox delivery.
- `Status` and `All` modes are intentionally verbose.
- The tool has been developed against observed IX Messaging behavior; different IXM releases may use different log wording.

## Version history

See [CHANGELOG.md](CHANGELOG.md).
