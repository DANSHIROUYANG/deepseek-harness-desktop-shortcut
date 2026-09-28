<#
    安装：把启动器与图标装到 %USERPROFILE%\.dsh\launcher，并在桌面创建快捷方式。

    用法：
      powershell -NoProfile -ExecutionPolicy Bypass -File src\install.ps1
      powershell -NoProfile -ExecutionPolicy Bypass -File src\install.ps1 -NoShortcut

    做两件事：
      1. 复制 src\open-dsh.ps1、src\open-dsh.vbs 到 %USERPROFILE%\.dsh\launcher，
         并把 assets\dsh.ico 按**内容哈希**命名安装（例如 dsh-c08b0603.ico）
      2. 桌面创建「DeepSeek Harness.lnk」，指向 wscript.exe + open-dsh.vbs，图标用上面那个文件

    为什么图标要按内容哈希命名：Windows 的图标缓存是**按文件路径**缓存的，原地覆盖同名
    .ico 通常不会刷新（桌面上还是旧图，清 ie4uinit 也未必管用）。换个文件名就彻底绕过缓存；
    装完还会广播一次 SHCNE_ASSOCCHANGED 并调用 ie4uinit -show 提醒 shell。

    卸载：删掉桌面上的快捷方式和 %USERPROFILE%\.dsh\launcher 目录即可。
#>
[CmdletBinding()]
param([switch]$NoShortcut)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $root 'src'
$assetsDir = Join-Path $root 'assets'
$dst = Join-Path $env:USERPROFILE '.dsh\launcher'
$ps1 = Join-Path $dst 'open-dsh.ps1'
$vbs = Join-Path $dst 'open-dsh.vbs'
$sourceIco = Join-Path $assetsDir 'dsh.ico'

foreach ($file in @((Join-Path $srcDir 'open-dsh.ps1'), (Join-Path $srcDir 'open-dsh.vbs'), $sourceIco)) {
    if (-not (Test-Path -LiteralPath $file)) { throw "缺少文件：$file（请在完整仓库里运行本脚本）" }
}

New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item -LiteralPath (Join-Path $srcDir 'open-dsh.ps1') -Destination $ps1 -Force
Copy-Item -LiteralPath (Join-Path $srcDir 'open-dsh.vbs') -Destination $vbs -Force

# 图标按内容哈希命名：文件名随内容变化，图标缓存就不会拿旧图糊弄
$icoHash = (Get-FileHash -LiteralPath $sourceIco -Algorithm SHA256).Hash.Substring(0, 8).ToLower()
$ico = Join-Path $dst ('dsh-' + $icoHash + '.ico')
Copy-Item -LiteralPath $sourceIco -Destination $ico -Force
Get-ChildItem -LiteralPath $dst -Filter '*.ico' | Where-Object { $_.FullName -ne $ico } | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Force
}

# Windows PowerShell 5.1 对无 BOM 的 .ps1 按 ANSI 解码，中文会把脚本解析坏掉。
$bytes = [System.IO.File]::ReadAllBytes($ps1)
if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
    throw 'open-dsh.ps1 缺少 UTF-8 BOM：请用仓库里的原始文件（不要另存为/复制粘贴），见 README 的说明。'
}

foreach ($path in @($ps1, $vbs, $ico)) {
    "已安装：$path（$((Get-Item -LiteralPath $path).Length) 字节）"
}

if (-not $NoShortcut) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desktop 'DeepSeek Harness.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($lnk)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $shortcut.Arguments = '"' + $vbs + '"'
    $shortcut.WorkingDirectory = $dst
    $shortcut.IconLocation = $ico + ',0'
    $shortcut.Description = 'DeepSeek Harness - open the Web GUI'
    $shortcut.WindowStyle = 7 # 最小化（配合 wscript 实际不显示任何窗口）
    $shortcut.Save()

    $check = $shell.CreateShortcut($lnk)
    "桌面快捷方式：$lnk"
    "  目标：$($check.TargetPath) $($check.Arguments)"
    "  图标：$($check.IconLocation)"

    # 告诉 shell 图标/关联已变，别再用缓存
    try {
        Add-Type -Namespace DshInstall -Name Shell -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern void SHChangeNotify(int eventId, uint flags, System.IntPtr item1, System.IntPtr item2);
'@
        [DshInstall.Shell]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero) # SHCNE_ASSOCCHANGED, SHCNF_IDLIST
    } catch {
        "（SHChangeNotify 不可用：$($_.Exception.Message)；图标仍会在下次登录后刷新）"
    }
    Start-Process -FilePath 'ie4uinit.exe' -ArgumentList '-show' -WindowStyle Hidden
}

'完成。双击桌面上的「DeepSeek Harness」即可；自检可运行 tools\verify.ps1。'
