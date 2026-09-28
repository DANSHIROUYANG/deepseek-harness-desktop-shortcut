<#
    自检：验证已安装的启动器（默认 %USERPROFILE%\.dsh\launcher）。

    用法：
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify.ps1
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify.ps1 -SkipCold
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify.ps1 -ColdPort 3099

    它会检查：
      1. 启动器能被 Windows PowerShell 5.1 正确解析（0 语法错误），函数齐全
      2. dsh 入口解析结果、端口探测、日志里 token 地址的正则
      3. 热启动：目标端口已在监听时，会打开哪个地址（跳过启动动作，避免真把服务拉起来）
      4. 冷启动：在 -ColdPort 上真的走一遍「后台起服务 → 取带 token 的地址」，然后关掉

    两个刻意的取舍：
      * 全程用 DSH_LAUNCHER_NO_BROWSER=1，只把要打开的地址写进 dsh-dryrun.txt，不弹浏览器。
      * 刻意不把启动器的输出接进管道：后台服务会继承启动器的 stdout 句柄，用管道收集输出
        会一直等不到 EOF（作者在这里踩过坑）。
#>
[CmdletBinding()]
param(
    [string]$LauncherDir = (Join-Path $env:USERPROFILE '.dsh\launcher'),
    [int]$WarmPort = 3080,
    [int]$ColdPort = 3099,
    [switch]$SkipCold
)

$ErrorActionPreference = 'Stop'

$ps1 = Join-Path $LauncherDir 'open-dsh.ps1'
$vbs = Join-Path $LauncherDir 'open-dsh.vbs'
$ico = Join-Path $LauncherDir 'dsh.ico'
$pidFile = Join-Path $LauncherDir 'dsh-web.pid'
$dryRun = Join-Path $LauncherDir 'dsh-dryrun.txt'

function Test-TcpPort {
    param([string]$TargetHost = '127.0.0.1', [int]$TargetPort)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect($TargetHost, $TargetPort, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(1000)) { return $false }
        $client.EndConnect($pending)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Mask-Secret {
    param([string]$Text)
    return ($Text -replace 'token=[A-Za-z0-9\-_]+', 'token=<masked>')
}

# 等 dsh-dryrun.txt 里出现第 ($FromLine + 1) 行，即本次启动器的决策。
function Wait-Decision {
    param([int]$FromLine, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (-not (Test-Path -LiteralPath $dryRun)) { continue }
        $lines = @(Get-Content -LiteralPath $dryRun)
        if ($lines.Count -gt $FromLine) { return $lines[$lines.Count - 1] }
    }
    return $null
}

function Start-Launcher {
    param([int]$ProbePort)
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $ps1, '-Port', [string]$ProbePort
    ) | Out-Null
}

function Get-DecisionCount {
    if (-not (Test-Path -LiteralPath $dryRun)) { return 0 }
    return @(Get-Content -LiteralPath $dryRun).Count
}

'== 1. 安装文件 =='
foreach ($path in @($ps1, $vbs, $ico)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "缺少 $path，先运行 src\install.ps1" }
    "  ok  $path ($((Get-Item -LiteralPath $path).Length) 字节)"
}
$bytes = [System.IO.File]::ReadAllBytes($ps1)
if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { '  ok  open-dsh.ps1 带 UTF-8 BOM' } else { '  警告：open-dsh.ps1 没有 BOM，PowerShell 5.1 可能解析失败' }

'== 2. 解析与函数 =='
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    foreach ($err in $errors) { "  L$($err.Extent.StartLineNumber): $($err.Message)" }
    throw "open-dsh.ps1 有 $($errors.Count) 个语法错误"
}
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
"  ok  0 语法错误，函数：$(($funcs | ForEach-Object { $_.Name }) -join ', ')"
foreach ($f in $funcs) { Invoke-Expression $f.Extent.Text }

$launch = Resolve-DshLaunch -RequestedProfile 'web' -RequestedPort $ColdPort
if ($launch) { "  ok  dsh 入口：$($launch.Command)" } else { throw '  dsh 入口解析失败（找不到 node/npx/dsh）' }
"  ok  端口探测：$WarmPort -> $(Test-TcpPort -TargetPort $WarmPort)，$ColdPort -> $(Test-TcpPort -TargetPort $ColdPort)"
$sample = 'dsh web: http://127.0.0.1:3080/?token=AbC-123_xyz (LAN: http://192.168.1.7:3080/?token=AbC-123_xyz)'
$matched = [regex]::Match($sample, 'http://127\.0\.0\.1:\d+/\?token=[A-Za-z0-9\-_]+').Value
if ($matched) { "  ok  token 地址正则：$matched" } else { throw '  token 地址正则匹配失败' }

$env:DSH_LAUNCHER_NO_BROWSER = '1'
Remove-Item -LiteralPath $dryRun -Force -ErrorAction SilentlyContinue

'== 3. 热启动（服务已在监听）=='
if (Test-TcpPort -TargetPort $WarmPort) {
    $mark = Get-DecisionCount
    Start-Launcher -ProbePort $WarmPort
    $decision = Wait-Decision -FromLine $mark -TimeoutSeconds 30
    if ($decision) { "  ok  会打开：$(Mask-Secret $decision)" } else { '  失败：30 秒内没有看到决策（检查 open-dsh.ps1）' }
} else {
    "  跳过：$WarmPort 上没有服务在跑；这时热启动会真的把服务拉起来，所以只做冷启动演练"
}

if (-not $SkipCold) {
    '== 4. 冷启动（真的起一个服务）=='
    if (Test-TcpPort -TargetPort $ColdPort) {
        "  跳过：$ColdPort 已被占用，请换 -ColdPort"
    } else {
        $mark = Get-DecisionCount
        Start-Launcher -ProbePort $ColdPort
        $decision = Wait-Decision -FromLine $mark -TimeoutSeconds 120
        if ($decision) { "  ok  会打开：$(Mask-Secret $decision)" } else { "  失败：120 秒内没有拿到带 token 的地址" }
        $listening = Test-TcpPort -TargetPort $ColdPort
        "  服务监听 $ColdPort：$listening"
        if (Test-Path -LiteralPath $pidFile) {
            $serverPid = [int](Get-Content -LiteralPath $pidFile)
            "  关闭测试服务 pid $serverPid"
            taskkill /PID $serverPid /T /F | Out-Null
            Start-Sleep -Seconds 2
            "  清理后 $ColdPort 空闲：$(-not (Test-TcpPort -TargetPort $ColdPort))"
        }
    }
}

Remove-Item Env:\DSH_LAUNCHER_NO_BROWSER -ErrorAction SilentlyContinue
"决策记录留在：$dryRun（含一次性 token，可随时删除）"
