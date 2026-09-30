# traceIXM

`traceIXM` is a standalone, read-only PowerShell live-trace utility for **Avaya IX Messaging**.

It follows active IX Messaging Voice Server and DBCOM logs and correlates them into a live console view similar in spirit to an Avaya Communication Manager `list trace` session.

> This is an independent troubleshooting utility. It is not an Avaya product and does not modify IX Messaging configuration or data.

## Current version

**1.1.1**

PowerShell **5.1+**.

## What it traces

The default `Summary` view correlates:

- call start / calling / called identity from IDMS
- IXM channel number
- subscriber mailbox login
- live DTMF digits
- password-entry DTMF
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
16:49:38.317 STATUS  CH 1  DTMF         Digit=2  Context=Password
16:49:39.494 STATUS  CH 1  DTMF         Digits=580#  Context=Password
16:49:39.590 STATUS  CH 1  LOGIN OK     Subscriber mailbox login successful  Mailbox=10000  MbxID=91
16:49:39.757 STATUS  CH 1  MENU         Menu 102/Level1  State=103
16:49:59.457 STATUS  CH 1  ROUTE        Menu 102/Level1 --[4]--> Menu 102/Level8
16:50:03.393 STATUS  CH 1  ROUTE        Menu 102/Level8 --[6]--> Menu 102/Level29
...
16:50:20.000 STATUS  CH 1  CALL END     Duration=50.2 sec  Mailbox=10000
16:50:20.000 STATUS  CH 1  CALL PATH    10000 -> 10099 | Login mailbox 10000 | Menu 102/Level1 | Menu 102/Level1 --[4]--> Menu 102/Level8 | Menu 102/Level8 --[6]--> Menu 102/Level29
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

Default correlated trace:

```powershell
.\traceIXM.ps1
```

Trace only one IXM channel:

```powershell
.\traceIXM.ps1 -Channel 1
```

Filter output for a mailbox, extension, number, GUID, or other text:

```powershell
.\traceIXM.ps1 -Match 10005
```

Write the displayed trace to a file:

```powershell
.\traceIXM.ps1 -OutputPath C:\Temp\traceIXM.txt
```

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

Clone the private repository:

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
- Friendly menu-action names are not inferred.
- Some SIP/MWI events do not contain a channel number and are therefore displayed as `CH --` unless reliable correlation is available.
- DBCOM synchronization may occur asynchronously after the originating call.
- `EXT SYNC OK` confirms the IXM synchronization record, not final recipient inbox delivery.
- `Status` and `All` modes are intentionally verbose.
- The tool has been developed against observed IX Messaging behavior; different IXM releases may use different log wording.

## Version history

See [CHANGELOG.md](CHANGELOG.md).