# Changelog

## 1.2.5

- Added high-confidence `CALL RESULT` classification at call end.
- Added `VOICEMAIL SAVED`, `RECORDING ENDED - NO MESSAGE SAVED`, `RECORDING STARTED - NO MESSAGE SAVED`, `HUNG UP BEFORE RECORDING`, `SUBSCRIBER SESSION`, and `CALL ENDED - OUTCOME UNKNOWN` outcomes.
- Added per-call mailbox/recording/message-save state tracking from IXM application events.
- Fixed stale mailbox/message metadata when IXM reuses a channel for a new call.
- Added recording duration to the result when IXM logs `Actual Message Play Time`.
- Updated the interactive Calls view to retain the last completed call result for each channel.
- The classifier deliberately does not infer dead air or audio quality.

## 1.2.4

- Added a separate deduplicated Summary event history so the interactive Summary pane no longer repeats identical IXM events such as duplicate INMSGSTART/INMSGEND, media timing, or recording records.
- Raw capture history remains intact for SIP view, filtering, and ZIP export.
- Added a 1.25-second post-BYE/CANCEL completion grace period before emitting CALL END.
- The grace period allows late IX Messaging mailbox/recording/message-store records to enrich the completed call before the session is finalized.
- CALL END keeps the SIP disconnect timestamp/duration while using the latest correlated mailbox state available during the grace period.
- Existing read-only behavior, password/PIN masking, and classic command-line modes are unchanged.

## 1.2.3

- Suppressed the classic startup banner and source-file listing in interactive mode.
- Added a one-time canvas reset after startup/filter/help/export dialogs so the persistent UI does not leave old menu/setup text on screen.
- Kept the live refresh path flicker-free with in-place redraws.

## 1.2.2

- Replaced per-refresh `Clear-Host` with in-place console cursor redraws to eliminate visible screen blinking.
- Added cleanup for leftover rows when a refreshed frame is shorter than the previous frame.
- Preserved modal menu/help/export clears as one-time transitions only.

## 1.2.1

- Reworked interactive mode into a persistent console UI instead of a continuously scrolling trace.
- Added dedicated Summary, SIP, and Calls screens selectable with `1`, `2`, and `3`.
- Added a persistent header showing the current filter, view, captured/matched event counts, SIP count, active-call count, and capture start time.
- Summary and SIP screens automatically show the most recent rows that fit the current console height.
- Calls screen displays the current per-channel caller/called/mailbox/session state.
- Existing `S` and `C` shortcuts remain available as aliases.
- Added explicit startup selection `0` for starting/continuing with no filter.
- Preserved non-interactive command-line behavior and capture export.

## 1.2.0

- Added a traceSM-style interactive startup filter menu.
- Added dedicated filters for extension/mailbox, caller ID, called number, IXM channel, SIP Call-ID, IP address, and text.
- Extension/caller/called filtering is session-aware: once a matching IXM channel is identified, related TUI/menu events continue to be shown.
- Added runtime hotkeys: `F` change filter, `S` Summary/SIP view, `C` call summary, `W` capture export, `H` help, and `Q` quit.
- Added an interactive SIP view backed by IX Messaging `SIP#YYYYMMDD.log` and `RVSIP#YYYYMMDD.log`.
- Added in-memory capture retention (bounded to 10,000 parsed events).
- Added ZIP troubleshooting export containing `traceIXM.txt`, `sip.txt`, `filter.json`, and `sessions.json`.
- Preserved the existing command-line modes and `-OutputPath` behavior for backward compatibility.
- Added `-Interactive` and `-NoInteractive` switches.
- The new SIP view remains read-only and log-based; it does not enable packet capture or modify IX Messaging.

## 1.1.2

- Fixed false `CALL END` events caused by treating Voice Server Event 28 / `ResetChannel()` as a session boundary.
- `CALL END` now uses a correlated SIP `BYE` or `CANCEL`; channel-less disconnects are correlated only when exactly one IXM call is active.
- Fixed duplicate `IDMS` output immediately following `CALL START`.
- Improved SIP request detection when IXM prefixes SIP log lines with timestamps/thread information.
- `CALL PATH` now retains normal menu keypresses that do not change menu levels.
- When a keypress does cause a level transition, the pending keypress entry is upgraded to a `ROUTE` entry rather than duplicated.
- Password/PIN digits remain always hidden.

## 1.1.1

- Security change: subscriber password/PIN DTMF is now always hidden.
- Removed the option to display password/PIN digits.
- Normal menu DTMF remains visible for call-flow troubleshooting.
- `Status` and `All` forensic modes redact password-bearing IXM log fields.
- `-OutputPath` never receives the subscriber password/PIN from parsed trace events.
- Invalid authentication continues to report `LOGIN FAILED` without exposing the entered password.

## 1.1.0

- Added operator-oriented `CALL START` event in Summary mode.
- Added per-channel active-call correlation and call duration.
- Added `CALL END` and reconstructed `CALL PATH` output at Voice Server channel reset.
- Collapsed repetitive `Custom Menu` state 100/101/102 churn in Summary mode.
- Added `ROUTE` events that correlate a DTMF choice to the next observed custom-menu level.
- Added friendly compact menu formatting such as `Menu 102/Level8`.
- Preserved DTMF buffer continuity across password-request states so cumulative IXM buffers produce only newly entered digits.
- Improved duplicate Trace state suppression by comparing the original log timestamps rather than parser arrival time.
- Retained `Status` mode as the forensic/raw evidence view.
- DTMF/password digits remain visible by default for troubleshooting.
- `-MaskSensitiveDigits` remains available for redacted output.
- Continued suppression of unrelated background DBCOM synchronization in Summary unless it correlates to a message seen by the current trace session.

## 1.0.10

- Changed DTMF troubleshooting default to display password-entry digits.
- Added optional `-MaskSensitiveDigits`.
- Fixed empty DTMF buffer parser exception.

## 1.0.9

- Added subscriber TUI parsing from the Voice Server STATUS log.
- Added `AUTH`, `DTMF`, `MENU`, `LOGIN OK`, `LOGIN FAILED`, and `MSG COUNT`.
- Added custom-menu level detection.
- Added initial password masking behavior.
- Suppressed unrelated background external-sync records from Summary.

## 1.0.8

- Added DBCOM live tracing.
- Added EEAMHELPER `MessageAddInternal` parsing.
- Added TSECMGR `InternalUpdateSyncStatusOfMessage` parsing.
- Added numeric IXM MessageID correlation.
- Added external SyncID handling.
- Added explicit Graph/SMTP success/failure detection when logged.

## 1.0.7

- Improved duplicate state suppression.
- Generalized IXM integration-suffix removal.
- Renamed `EEAM.GetPlayTime` output to `EEAM PLAYTIME`.

## 1.0.6

- Added pending physical-line buffering.
- Added STATUS/SIP thread-to-channel correlation.
- Added MWI count parsing.
- Added `MESSAGE LENGTH` and `VOX LENGTH`.
- Improved voicemail-save channel correlation.

## 1.0.4

- Reworked the live parser for Windows PowerShell 5.1 compatibility.

## 1.0.1 - 1.0.3

- Initial standalone live-tail implementation.
- Fixed Windows PowerShell 5.1 FileStream/StreamReader constructor issues.