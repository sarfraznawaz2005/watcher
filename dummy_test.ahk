#Requires AutoHotkey v2.0+
#SingleInstance Force
#Warn
Persistent(true)
; Intentionally broken script to exercise Watcher.

; ERROR #1: Invalid regular expression (unbalanced parenthesis)
RegExMatch("abc", "(")

; ERROR #2: Division by zero (will be reached after fixing ERROR #1)
x := 10 / 0

; ERROR #3: Calling method on a non-object (will be reached after fixing ERROR #2)
y := 5
y.Push(123)
