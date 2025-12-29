# Watcher (AutoHotkey v2)

A small AutoHotkey v2 utility that watches another AHK script for runtime Warning/Error dialogs and writes details to a log. This repo contains two variants:

- `Watcher.ahk` (current, UI watcher): does not run the target; it monitors windows, logs errors, and offers a tray UI.
- `Watcher - Copy.ahk` (full runner): launches the target with `/ErrorStdOut`, mirrors stderr, supports headless/timeout/signal re-run. Use this when you need an automated runner.

## Requirements

- AutoHotkey v2.0+ installed. Default path assumed: `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`.
- Windows 10/11 (uses WMI + standard window APIs).

## Quick Start (UI Watcher)

- Run: `"C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe" Watcher.ahk`
- Paste or browse to your target script path.
- Click `Start` (the window hides to the tray).
- Make the target show an AHK error/warning dialog. Watcher will:
  - Overwrite `error.log` in the target script folder with the latest dialog text.
  - Append details to `%TEMP%\\ahk-watcher-debug.log`.
- Single-click the tray icon to show the UI again.

## What Gets Logged

- `error.log` (in the target folder):
  - Contains only the latest error/warning dialog (file is truncated each time a new dialog is captured).
  - Automatically deleted when you click `Start` and whenever the target file changes on disk.
- `ahk-watcher-debug.log` (in `%TEMP%`):
  - Cleared once on watcher startup.
  - Receives debug entries (state changes, dialog metadata) and the full dialog content for quick inspection.

## Features (UI Watcher)

- Watches the target script’s windows (by PID if resolvable; falls back to title match).
- Captures typical AHK warning/error dialogs and extracts their text.
- File-change detection: if the watched script changes (modified time/size), watcher deletes `error.log` and notes the event in the debug log.
- Tray tooltip shows status: `WATCHING` or `NOT WATCHING` on hover.
- Tray menu:
  - `Show`: bring the UI to front (also the default single-click action).
  - `Open Debug Log`: opens `%TEMP%\\ahk-watcher-debug.log` in Notepad.
  - `Reload`: reloads the watcher script itself.
  - `Exit`: stops and exits.

## Notes & Behavior

- The watcher refuses to watch itself.
- Generic UI heuristics are used to detect AHK dialogs (common button labels + title/content checks). Normal app MsgBoxes are usually ignored unless they resemble AHK error/warning text.
- The UI no longer shows the last message textbox; all details go to the logs.

## Full Runner Variant (optional)

Use `Watcher - Copy.ahk` when you also want the watcher to run your script, capture `/ErrorStdOut`, and support automation.

- Example: `"C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe" "Watcher - Copy.ahk" --headless --script="C:\\path\\to\\target.ahk" --timeout=20`
- Notable flags (runner variant): `--script=PATH`, `--headless/--once`, `--timeout=SEC`, `--bring-dialog`, `--stop-on-error`, optional re-run signal file.
- Runner variant may maintain `stderr.log` and write a `summary.txt`. See comments in that script for the full list of options.

## Troubleshooting

- No `error.log` appears: ensure the target actually raised an AHK error/warning dialog; or try the runner variant for `/ErrorStdOut` capture.
- Wrong script being matched: set the full path in the watcher; title-based fallback tries to match the target filename.
- Nothing happens: make sure you’re on AHK v2 and not v1; check `%TEMP%\\ahk-watcher-debug.log` for details.

## Development Tips

- Code style: pure AutoHotkey v2 (expression syntax, functions, `Gui()` API, `try/catch`).
- Logging helpers: `LogDebug()` (temp debug log) and `_AppendLog()` (target `error.log`, overwrite mode).
- High-risk calls are wrapped in `try/catch`; update or add logs as needed when extending the watcher.

