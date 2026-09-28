' DeepSeek Harness desktop shortcut launcher.
' wscript.exe is a GUI-subsystem host, so this shim can start PowerShell with no
' console window at all (a .lnk pointing straight at powershell.exe would flash one).
' ASCII only on purpose: .vbs files are read with the ANSI code page, so the
' user profile path is expanded at run time instead of being written here.
Option Explicit

Dim shell, command
Set shell = CreateObject("WScript.Shell")

command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ _
  & shell.ExpandEnvironmentStrings("%USERPROFILE%") & "\.dsh\launcher\open-dsh.ps1"""

' 0 = hidden window, False = do not wait for it to finish.
shell.Run command, 0, False
