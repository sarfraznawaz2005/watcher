#Requires AutoHotkey v2.0+
#SingleInstance Off

; A standalone AutoHotkey v2 error watcher.
; - Watches for AHK warning/error dialogs from a provided script path
; - Appends dialog content to error.log in the target folder
; - Does not run/kill/re-run the target script

class Constants {
    static WATCH_INTERVAL := 700  ; Increased from 300ms for better performance
    static FILE_CHECK_INTERVAL := 300  ; Increased from 500ms
    static MAX_BUTTONS := 10
    static MAX_CONTROLS := 10
    static NOTIFICATION_DURATION := 5
    static RETRY_ATTEMPTS := 10
    static RETRY_DELAY := 100
}

class WatcherApp {
    __New() {
        this.watching := false
        this.targetPath := ""
        this.targetDir := ""
        this.winTimer := 0
        this.seen := Map()
        this.argScript := ""
        this.ui := ""
        this.edPath := ""
        this.btnBrowse := ""
        this.btnStart := ""
        this.childPid := 0
        this.previousPid := 0
        this.winTimerFunc := ""
        this.watchedFileTime := ""
        this.watchedFileSize := -1
        this.fileWatchTimerFunc := ""
        this.scriptTitle := ""
        this.iniLastScript := ""
    }

    ; Helper function for enumerating controls to reduce code duplication
    EnumerateControls(hwnd, controlClasses, maxControls := Constants.MAX_CONTROLS) {
        best := ""
        bestLen := 0

        for cl in controlClasses {
            idx := 1
            loop maxControls {
                cn := cl idx
                try t := ControlGetText(cn, "ahk_id " hwnd)
                Catch as e {
                    break
                }

                if (StrLen(t) > bestLen) {
                    best := t
                    bestLen := StrLen(t)
                }
                idx += 1
            }
        }
        return best
    }
}

global app := WatcherApp()

try FileDelete(GetDebugLogPath())

InitFromArgs()
BuildUi()
InitTray()
Persistent()

return

InitFromArgs() {
    global app

    _LoadSettings()

    app.argScript := ""

    ; Delete session debug log in temp at watcher startup
    try FileDelete(GetDebugLogPath())

    ; positional for compatibility
    if (A_Args.Length >= 1 && SubStr(A_Args[1],1,2) != "--")
        app.argScript := A_Args[1]

    ; named
    for a in A_Args {
        if (SubStr(a,1,9) = "--script=")
            app.argScript := SubStr(a,10)
    }
}

BuildUi() {
    global app

    ui := Gui()
    app.ui := ui

    ui.Opt("-AlwaysOnTop +OwnDialogs")
    ui.MarginX := 10, ui.MarginY := 10
    ui.AddText(, "Script to watch (full path):")

    ed := ui.AddEdit("w560")

    app.edPath := ed

    btnBrowse := ui.AddButton("w80", "Browse")
    btnBrowse.OnEvent("Click", BrowseScript)

    app.btnBrowse := btnBrowse

    ; Options removed: force/auto-exit/auto-close/bring/auto-rerun
    ; Removed "Last message" UI per request
    btnStart := ui.AddButton("Default x+10 yp w120", "Start")
    btnStart.OnEvent("Click", ToggleStart)

    app.btnStart := btnStart

    ui.OnEvent("Close", UiClose)
    ui.Title := "Watcher.ahk - AHK Error/Warning Watcher"
    ui.Show("AutoSize")
    ; No dynamic alignment; Start sits next to Browse reliably

    ; Pre-fill from args or persisted lastScript (no auto-start by default)
    if (app.argScript != "")
        app.edPath.Value := app.argScript
    else if (app.iniLastScript != "")
        app.edPath.Value := app.iniLastScript
}

BrowseScript(*) {
    global app

    ini := A_ScriptDir "\\Watcher.ini"
    lastDir := IniRead(ini, "ui", "lastDir", A_ScriptDir)
    fp := FileSelect(3, lastDir, "Select AHK script to watch", "AHK Scripts (*.ahk)")

    if (fp != "") {
        app.edPath.Value := fp
        try IniWrite(DirExist(fp)?fp:SubStr(fp,1,InStr(fp,"\",, -1)-1), ini, "ui", "lastDir")
    }
}

ToggleStart(*) {
    global app

    if !app.watching {
        StartWatching()
        try app.ui.Hide() ; hide to system tray on start
    } else {
        StopWatching()
    }
}

StartWatching() {
    global app

    target := Trim(app.edPath.Value)

    if (target = "" || !FileExist(target)) {
        MsgBox("Please select a valid .ahk script path.")
        return
    }

    ; Do not allow watching itself
    if (StrLower(target) = StrLower(A_ScriptFullPath)) {
        MsgBox("Watcher cannot watch itself. Please choose another script.")
        return
    }

    app.targetPath := target
    SplitPath(target, &name, &dir)
    app.targetDir := dir
    app.scriptTitle := name ; warning/error dialog title is usually the script filename

    ; clear previous error.log at start
    logp := GetLogPath()
    try FileDelete(logp)

    ; Save UI settings (do not write to error.log to avoid confusing agents)
    _SaveSettings()
    ; resolve child PID by command line (non-invasive)
    app.childPid := _ResolveChildPid(target)
    app.previousPid := app.childPid

    if (app.childPid) {
        try FileDelete(GetLogPath())
    }

    app.winTimerFunc := _OnWatchWindows
    SetTimer(app.winTimerFunc, Constants.WATCH_INTERVAL)

    ; initialize file-change watch on the target script
    try {
        app.watchedFileTime := FileGetTime(target, "M")
    } Catch as e {
        app.watchedFileTime := ""
    }

    try {
        app.watchedFileSize := FileGetSize(target)
    } Catch as e {
        app.watchedFileSize := -1
    }

    app.fileWatchTimerFunc := _OnFileWatch
    SetTimer(app.fileWatchTimerFunc, Constants.FILE_CHECK_INTERVAL)

    app.watching := true
    app.btnStart.Text := "Stop"

    LogDebug("Started watching: " . app.targetPath . " pid=" . app.childPid)
    _UpdateTrayTip()
}

StopWatching() {
    global app

    try SetTimer(app.winTimerFunc, 0)
    try SetTimer(app.fileWatchTimerFunc ? app.fileWatchTimerFunc : 0, 0)

    app.winTimerFunc := 0
    app.fileWatchTimerFunc := 0
    app.childPid := 0
    app.previousPid := 0
    app.watching := false
    app.btnStart.Text := "Start"

    if (app.targetPath != "")
        LogDebug("Stopped watching: " . app.targetPath)

    _UpdateTrayTip()
}

StopAndExit(*) {
    StopWatching()
    ; Graceful shutdown: cleanup resources
    try FileDelete(GetDebugLogPath())
    ExitApp()
}

_OnWatchWindows() {
    global app

    ; Try to resolve child PID if not yet known
    if (!app.childPid) {
        if (app.targetPath != "")
            app.childPid := _ResolveChildPid(app.targetPath)
        if (app.childPid) {
            try FileDelete(GetLogPath())
            app.previousPid := app.childPid
            LogDebug("Resolved child PID: " . app.childPid)
        }
    }

    ; Primary: scan windows belonging to child PID
    list := []
    if (app.childPid) {
        try list := WinGetList("ahk_pid " app.childPid)
        Catch as e {
            list := []
        }
    }

    if (app.childPid && list.Length == 0) {
        app.childPid := 0
    }

    ; Fallback: if still nothing, scan by title match to the script filename only
    if (list.Length = 0 && app.scriptTitle != "") {
        try all := WinGetList()
        Catch as e {
            all := []
        }

        for h in all {
            try ttl := WinGetTitle("ahk_id " h)
            Catch as e2 {
                continue
            }

            if (ttl = app.scriptTitle) {
                list.Push(h)
            }
        }
    }

    if (list.Length = 0)
        return

    for hwnd in list {
        ; Never act on our own windows (compare with current process ID)
        try {
            selfPid := DllCall("GetCurrentProcessId", "uint")
            if (WinGetPID("ahk_id " hwnd) = selfPid)
                continue
        } Catch as e {
        }

        if app.seen.Has(hwnd)
            continue

        title := ""
        try title := WinGetTitle("ahk_id " hwnd)
        cls := ""
        try cls := WinGetClass("ahk_id " hwnd)

        ; Only consider visible windows
        if !WinExist("ahk_id " hwnd)
            continue

        ; Heuristic: look for presence of known buttons on this window
        btns := ["Help","Edit","Reload","ExitApp","Continue","Abort"]
        found := 0

        ; Use helper function to reduce code duplication
        for b in btns {
            if (app.EnumerateControls(hwnd, ["Button"], Constants.MAX_BUTTONS) ~= b) {
                found += 1
            }
        }

        ; Extract content first for content-based matching
        content := app.EnumerateControls(hwnd, ["RICHEDIT50W","RichEditD2DPT","RichEdit20A","RichEdit20W","Edit","Static"])

        if (content = "")
            try content := WinGetText("ahk_id " hwnd)

        isError := (found >= 1)

        try {
            if (!isError && IsSet(content) && content != "") {
                if (RegExMatch(content, "im)^(?:Error|Warning)\s*:\s*"))
                    isError := true
            }
        } Catch as e {
        }

        if (isError) {
            app.seen[hwnd] := true

            ; Mark and notify (single detailed notification later)
            LogDebug(Format("Dialog matched: hwnd={1} title={2} class={3}", hwnd, title, cls))
            _AppendLog(Format("[{1}] DIALOG DETECTED: {2}`r`n{3}", Now(), title, content))

            ; Also mirror full content into debug log for quick inspection
            if (IsSet(content) && content != "")
                LogDebug(Format("Dialog content for {1}:{2}`r`n{3}", title, "", content))

            ; UI last-message field removed
            snip := (StrLen(content) > 160) ? SubStr(content, 1, 160) "???" : content
            Notify("Watcher: Dialog", snip)

            ; Auto-close error/warning dialog to allow target to continue or exit.
            labels := ["ExitApp","Abort","Continue"]

            if (_ClickOneOf(hwnd, labels) = 0) {
                try WinClose("ahk_id " hwnd)
                Catch as e {
                }
            }
        } else {
            LogDebug(Format("Skipped window: hwnd={1} title={2} class={3} foundButtons={4}", hwnd, title, cls, found))
        }
    }
}

_ResolveChildPid(targetPath) {
    try {
        svc := ComObjGet("winmgmts:")
        q := "Select ProcessId,CommandLine from Win32_Process where Name='AutoHotkey64.exe' or Name='AutoHotkey.exe'"
        procs := svc.ExecQuery(q)

        for p in procs {
            cl := p.CommandLine
            if (IsSet(cl) && cl != "" && InStr(cl, targetPath))
                return p.ProcessId
        }
    } Catch as e {
    }

    return 0
}

Notify(title, text := "", secs := Constants.NOTIFICATION_DURATION) {
    try {
        TrayTip(title, text)

        if (secs > 0) {
            clear := (*) => (TrayTip(), 0)
            SetTimer(clear, -secs * 1000)
        }
    }
}

_ClickOneOf(hwnd, labels) {
    for label in labels {
        if (_ClickButton(hwnd, label))
            return 1
    }

    return 0
}

_ClickButton(hwnd, label) {
    loop Constants.MAX_BUTTONS {
        cn := "Button" A_Index
        try txt := ControlGetText(cn, "ahk_id " hwnd)
        Catch as e {
            continue
        }

        if (txt = label) {
            try {
                ControlFocus(cn, "ahk_id " hwnd)
                PostMessage(0x00F5, 0, 0, cn, "ahk_id " hwnd) ; BM_CLICK
                Sleep Constants.RETRY_DELAY
                return WinExist("ahk_id " hwnd) ? 0 : 1
            } Catch as e {
            }
        }
    }

    return 0
}



GetLogPath() {
    global app
    return app.targetDir "\\error.log"
}

GetDebugLogPath() {
    ; Store debug log in Windows temp folder
    return A_Temp "\\ahk-watcher-debug.log"
}

_AppendLog(line) {
    ; Overwrite error.log so it contains only the latest error
    _SafeWriteExclusive(GetLogPath(), line "`r`n")
}

Now() {
    return FormatTime(, "yyyy-MM-dd HH:mm:ss")
}

_SafeAppend(path, text) {
    attempts := 0

    while (attempts < Constants.RETRY_ATTEMPTS) {
        try {
            FileAppend(text, path, "UTF-8")
            return
        } Catch as e {
            msg := e.Message

            if (InStr(msg, "(32)") || InStr(StrLower(msg), "being used by another process")) {
                Sleep Constants.RETRY_DELAY
                attempts += 1
                continue
            }

            break
        }
    }
}

_SafeWriteExclusive(path, text) {
    attempts := 0

    while (attempts < Constants.RETRY_ATTEMPTS) {
        try {
            f := FileOpen(path, "w", "UTF-8") ; truncate/create
            f.Write(text)
            f.Close()
            return
        } Catch as e {
            msg := e.Message

            if (InStr(StrLower(msg), "being used by another process") || InStr(msg, "(32)")) {
                Sleep Constants.RETRY_DELAY
                attempts += 1
                continue
            }
            break
        }
    }
}

InitTray() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Show", (*) => (app.ui.Show()))
    A_TrayMenu.Add()
    A_TrayMenu.Add("Open Debug Log", (*) => OpenDebugLog())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Reload", (*) => Reload())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", (*) => StopAndExit())

    try {
        A_TrayMenu.Default := "Show"
        A_TrayMenu.ClickCount := 1
    }

    _UpdateTrayTip()
}

UiClose(*) {
    try app.ui.Hide()
}

_IniPath() {
    return A_ScriptDir "\\Watcher.ini"
}

_LoadSettings() {
    global app

    ini := _IniPath()

    try {
        app.iniLastScript := IniRead(ini, "ui", "lastScript", "")
    } Catch as e {
    }
}

_SaveSettings() {
    global app

    ini := _IniPath()

    try {
        IniWrite(app.edPath.Value, ini, "ui", "lastScript")
    } Catch as e {
    }
}

LogDebug(msg) {
    FileAppend(Format("[{1}] DEBUG: {2}`r`n", Now(), msg), GetDebugLogPath(), "UTF-8")
}

_UpdateTrayTip() {
    try A_IconTip := (app.watching) ? "WATCHING - " . app.scriptTitle : "NOT WATCHING"

    ; Also update the tray icon based on watching state
    try {
        iconPath := (app.watching)
            ? A_ScriptDir "\\on.ico"
            : A_ScriptDir "\\off.ico"

        if FileExist(iconPath)
            TraySetIcon(iconPath)
    } Catch as e {
        ; ignore icon errors
    }
}

_OnFileWatch() {
    global app

    if !(app.targetPath != "")
        return

    tp := app.targetPath

    if !FileExist(tp)
        return

    changed := false
    curTime := ""
    curSize := -1

    try curTime := FileGetTime(tp, "M")
    Catch as e {
        curTime := ""
    }

    try curSize := FileGetSize(tp)
    Catch as e {
        curSize := -1
    }

    if (app.watchedFileTime != curTime)
        changed := true

    if (app.watchedFileSize != curSize)
        changed := true

    if (!changed)
        return

    ; update baseline and clear error.log to reflect fresh edits
    app.watchedFileTime := curTime
    app.watchedFileSize := curSize

    try {
        FileDelete(GetLogPath())
        LogDebug("Detected script change; cleared error.log")
    } Catch as e {
        LogDebug("Detected script change; failed to clear error.log: " . e.Message)
    }
}

OpenDebugLog() {
    path := GetDebugLogPath()

    if !FileExist(path) {
        ; Create an empty file so Notepad can open it
        try FileAppend("", path, "UTF-8")
    }

    Run('notepad.exe "' path '"')
}

; Hotkey to stop watching: Ctrl+Alt+S
^!s::StopWatching()
