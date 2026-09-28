<#
    DeepSeek Harness 桌面启动器
    ==========================
    由桌面图标 "DeepSeek Harness" 经 open-dsh.vbs 调用（全程无控制台窗口）。

    行为：
      1. 127.0.0.1:3080 上已经有 dsh web 在跑 -> 直接用默认浏览器打开它（秒开）。
      2. 没有在跑 -> 隐藏窗口启动 `dsh web --no-open`，从启动日志里取出带一次性
         token 的地址，再用默认浏览器打开。首次访问必须带这个 token 才能换取
         登录 Cookie，所以这一步不能直接用 http://127.0.0.1:3080/。

    启动日志：dsh-web.out.log / dsh-web.err.log（每次冷启动覆盖）
    后台服务 PID：dsh-web.pid（记录的是包着 node 的 cmd，用 /T 连子进程一起结束）
    停止后台服务：taskkill /PID (Get-Content "$env:USERPROFILE\.dsh\launcher\dsh-web.pid") /T /F

    自检钩子：环境变量 DSH_LAUNCHER_NO_BROWSER=1 时只打印将打开的地址，不启动浏览器。
#>
[CmdletBinding()]
param(
    [int]$Port = 3080,
    [string]$ProfileName = 'web',
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

$LauncherDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutLog = Join-Path $LauncherDir 'dsh-web.out.log'
$ErrLog = Join-Path $LauncherDir 'dsh-web.err.log'
$PidFile = Join-Path $LauncherDir 'dsh-web.pid'
$AppTitle = 'DeepSeek Harness'
$BaseUrl = 'http://127.0.0.1:' + [string]$Port

function Show-Dialog {
    param([string]$Message, [int]$Icon = 16)
    try { $null = (New-Object -ComObject WScript.Shell).Popup($Message, 0, $AppTitle, $Icon) } catch { }
}

function Test-PortOpen {
    param([int]$ProbePort)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect('127.0.0.1', $ProbePort, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(1000)) { return $false }
        $client.EndConnect($pending)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# dsh 启动时会把日志写进重定向文件；用共享读打开，避免和服务进程抢锁。
function Read-LogText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object System.IO.StreamReader($stream)
            return $reader.ReadToEnd()
        } finally { $stream.Dispose() }
    } catch {
        return ''
    }
}

# 找到可用的 dsh 入口：优先直接跑 node <bin.js>，避免多一层 cmd 窗口。
function Resolve-DshLaunch {
    param([string]$RequestedProfile, [int]$RequestedPort)

    # 探测的端口和服务实际监听的端口必须是同一个。
    $appArgs = ' ' + $RequestedProfile + ' --no-open --port ' + [string]$RequestedPort
    $node = $null
    $nodeCandidates = @(
        $env:DSH_NODE,
        (Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
        (Join-Path $env:ProgramFiles 'nodejs\node.exe')
    )
    foreach ($candidate in $nodeCandidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $node = $candidate; break }
    }

    $cliCandidates = New-Object System.Collections.ArrayList
    if ($env:DSH_CLI) { [void]$cliCandidates.Add($env:DSH_CLI) }
    # npx 缓存里的检出目录（npx 升级后会换哈希目录，所以按时间取最新的一个）
    $npxPattern = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx\*\node_modules\@deepseek-ai\dsh\lib\bin.js'
    foreach ($file in (Get-ChildItem -Path $npxPattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        [void]$cliCandidates.Add($file.FullName)
    }
    # 全局安装（如果哪天用 npm i -g 装过）
    [void]$cliCandidates.Add((Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\lib\bin.js'))
    [void]$cliCandidates.Add((Join-Path $env:ProgramFiles 'nodejs\node_modules\@deepseek-ai\dsh\lib\bin.js'))

    if ($node) {
        foreach ($cli in $cliCandidates) {
            if ($cli -and (Test-Path -LiteralPath $cli)) {
                return @{ Command = '"' + $node + '" "' + $cli + '"' + $appArgs; Label = $cli }
            }
        }
    }

    if (Get-Command dsh -ErrorAction SilentlyContinue) {
        return @{ Command = 'dsh' + $appArgs; Label = 'dsh (PATH)' }
    }
    if (Get-Command npx -ErrorAction SilentlyContinue) {
        return @{ Command = 'npx -y @deepseek-ai/dsh' + $appArgs; Label = 'npx -y @deepseek-ai/dsh' }
    }
    return $null
}

function Open-Url {
    param([string]$Url)
    if ($env:DSH_LAUNCHER_NO_BROWSER -eq '1') {
        # 自检钩子：不弹浏览器，只把将要打开的地址写下来。
        Write-Output ('open-dsh: would open ' + $Url)
        Add-Content -LiteralPath (Join-Path $LauncherDir 'dsh-dryrun.txt') -Value ((Get-Date).ToString('s') + ' ' + $Url) -Encoding UTF8
        return
    }
    Start-Process $Url | Out-Null
}

try {
    # 1) 服务已经在跑：直接开页面。
    if (Test-PortOpen -ProbePort $Port) {
        Open-Url $BaseUrl
        return
    }

    # 2) 冷启动：后台静默拉起 dsh web，等它打出带 token 的地址。
    $launch = Resolve-DshLaunch -RequestedProfile $ProfileName -RequestedPort $Port
    if ($null -eq $launch) {
        Show-Dialog "找不到 dsh 命令，也没找到 node/npx。`n`n请先安装 Node.js，或设置环境变量 DSH_CLI 指向 @deepseek-ai/dsh 的 lib\bin.js。"
        return
    }

    Remove-Item -LiteralPath $OutLog, $ErrLog, $PidFile -Force -ErrorAction SilentlyContinue
    # 日志重定向交给 cmd 自己做，CreateNoWindow 让服务和本进程彻底脱钩：
    # 不经过 PowerShell 的管道，启动器才能立刻退出，服务继续在后台跑。
    $innerCommand = $launch.Command + ' > "' + $OutLog + '" 2> "' + $ErrLog + '"'
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = '/c "' + $innerCommand + '"'
    $startInfo.WorkingDirectory = $env:USERPROFILE
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $server = [System.Diagnostics.Process]::Start($startInfo)
    Set-Content -LiteralPath $PidFile -Value $server.Id -Encoding ASCII

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $authenticatedUrl = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        $logText = (Read-LogText -Path $OutLog) + (Read-LogText -Path $ErrLog)
        $match = [regex]::Match($logText, 'http://127\.0\.0\.1:\d+/\?token=[A-Za-z0-9\-_]+')
        if ($match.Success) { $authenticatedUrl = $match.Value; break }
        if ($server.HasExited) { Start-Sleep -Milliseconds 700; break }
    }

    if ($authenticatedUrl) {
        Open-Url $authenticatedUrl
        return
    }
    # 我们起的进程没起来，但端口上已经有人应答（例如另一个实例刚好启动）
    if (Test-PortOpen -ProbePort $Port) {
        Open-Url $BaseUrl
        return
    }

    $tail = (Read-LogText -Path $ErrLog).Trim()
    if (-not $tail) { $tail = (Read-LogText -Path $OutLog).Trim() }
    if ($tail.Length -gt 600) { $tail = $tail.Substring($tail.Length - 600) }
    Show-Dialog ("DeepSeek Harness 在 " + [string]$TimeoutSeconds + " 秒内没能启动完成。`n`n启动方式：" + $launch.Label + "`n日志：" + $ErrLog + "`n`n" + $tail)
} catch {
    Show-Dialog ('DeepSeek Harness 启动器出错：' + $_.Exception.Message)
}
