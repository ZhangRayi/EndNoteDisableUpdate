#Requires -Version 5.1
<#
.SYNOPSIS
    阻止 EndNote 自动检查更新 / 弹窗催更新（EndNote 20、21、2025，Windows）。

.DESCRIPTION
    EndNote 启动后会用明文 HTTP 请求：
        http://download.endnote.com/updates/<大版本>/EN<大版本>WinUpdates.xml
    例如 22.0 版就是 .../updates/22.0/EN22WinUpdates.xml。
    如果清单里的版本比本机新，就弹窗问 "Would you like to install this update?"。

    本脚本做三件事：
      1) 在 hosts 里把 download.endnote.com 指向本机（这一层才是真正生效的封锁）；
      2) 把 HKLM 下 EndNote 各版本键里的 USERCANAPPLYUPDATES 改为 no（禁止应用更新）；
      3) 在 HKCU 偏好里写 CheckForUpdate / UserCanApplyUpdates = F（兜底）。

    执行前会自动备份 hosts 和相关注册表；用 -Undo 可以完整还原。

.PARAMETER Undo
    解除封锁，恢复自动更新检查。

.PARAMETER SkipBackup
    跳过自动备份（不建议）。

.PARAMETER NoElevate
    不自动请求管理员权限。没有管理员权限时 hosts 和 HKLM 改不了，会失败。

.PARAMETER KeepWindowOpen
    结束后暂停等待回车，方便双击运行时看结果（.cmd 启动器会自动带上）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\EndNote-BlockUpdate.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\EndNote-BlockUpdate.ps1 -Undo

.NOTES
    作者：DSH（根据 2026-11-22 在 EndNote 2025 22.0.0 build 19000 上的实测编写）
    只支持 Windows；只需要 PowerShell 5.1 或更新版本。
#>
[CmdletBinding()]
param(
    [switch]$Undo,
    [switch]$SkipBackup,
    [switch]$NoElevate,
    [switch]$KeepWindowOpen,
    [switch]$AdminPhase
)

$ErrorActionPreference = 'Stop'

$UpdateHost  = 'download.endnote.com'
$MarkerStart = '# --- endnote-update-block-start ---'
$MarkerEnd   = '# --- endnote-update-block-end ---'
$PrefsPath   = 'Software\ISI ResearchSoft\EndNote\Preferences'
$EndNoteKeys = 'SOFTWARE\ISI ResearchSoft\EndNote'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Head([string]$Text)  { Write-Host ''; Write-Host "=== $Text ===" -ForegroundColor Cyan }
function Write-Ok([string]$Text)    { Write-Host "  [完成] $Text" -ForegroundColor Green }
function Write-Note([string]$Text)  { Write-Host "  [信息] $Text" -ForegroundColor Gray }
function Write-Caution([string]$Text) { Write-Host "  [注意] $Text" -ForegroundColor Yellow }
function Write-Fail([string]$Text)  { Write-Host "  [失败] $Text" -ForegroundColor Red }

function Get-HostsPath {
    return (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')
}

function Get-EndNoteExe {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'EndNote 2025\EndNote.exe'),
        (Join-Path $env:ProgramFiles 'EndNote 2025\EndNote.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'EndNote 21\EndNote.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'EndNote 20\EndNote.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

# ---------- 用户级偏好（不需要管理员权限） ----------
function Set-UserPrefs {
    param([bool]$Enable)
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($PrefsPath)
    if (-not $key) { throw "无法创建注册表键 HKCU\$PrefsPath" }
    foreach ($name in @('CheckForUpdate', 'UserCanApplyUpdates')) {
        if ($Enable) {
            $key.SetValue($name, [string[]]@('F'), [Microsoft.Win32.RegistryValueKind]::MultiString)
        } else {
            $cur = $key.GetValue($name)
            if ($cur -is [string[]] -and (($cur -join '|') -eq 'F')) { $key.DeleteValue($name, $false) }
        }
    }
    $key.Close()
}

function Get-UserPrefs {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($PrefsPath)
    if (-not $key) { return @() }
    $out = @()
    foreach ($name in @('CheckForUpdate', 'UserCanApplyUpdates')) {
        $v = $key.GetValue($name)
        if ($null -ne $v) { $out += ('{0} = {1}' -f $name, (($v) -join '|')) }
    }
    $key.Close()
    return $out
}

# ---------- 机器级开关（需要管理员权限） ----------
function Set-MachineSwitch {
    param([string]$Value)
    $changed = @()
    foreach ($viewName in @('Registry32', 'Registry64')) {
        $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]$viewName)
        $base = $hive.OpenSubKey($EndNoteKeys, $true)
        if ($base) {
            foreach ($sub in @($base.GetSubKeyNames())) {
                $sk = $base.OpenSubKey($sub, $true)
                if ($sk) {
                    $sk.SetValue('USERCANAPPLYUPDATES', $Value, [Microsoft.Win32.RegistryValueKind]::String)
                    $changed += ('{0}\{1}' -f $viewName, $sub)
                    $sk.Close()
                }
            }
            $base.Close()
        }
        $hive.Close()
    }
    return $changed
}

function Get-MachineSwitch {
    $out = @()
    foreach ($viewName in @('Registry32', 'Registry64')) {
        $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]$viewName)
        $base = $hive.OpenSubKey($EndNoteKeys)
        if ($base) {
            foreach ($sub in @($base.GetSubKeyNames())) {
                $sk = $base.OpenSubKey($sub)
                if ($sk) {
                    $v = $sk.GetValue('USERCANAPPLYUPDATES')
                    if ($null -ne $v) { $out += ('{0}\{1} = {2}' -f $viewName, $sub, $v) }
                    $sk.Close()
                }
            }
            $base.Close()
        }
        $hive.Close()
    }
    return $out
}

# ---------- hosts ----------
function Update-HostsFile {
    param([switch]$Remove)
    $path = Get-HostsPath
    if (-not (Test-Path $path)) { throw "找不到 hosts 文件：$path" }

    $item = Get-Item $path -Force
    if ($item.IsReadOnly) { $item.IsReadOnly = $false }

    $lines = [System.IO.File]::ReadAllLines($path)
    $result = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    $removedOld = 0

    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -eq $MarkerStart) { $inBlock = $true; continue }
        if ($inBlock) { if ($t -eq $MarkerEnd) { $inBlock = $false }; continue }
        if (-not $Remove -and $t -notlike '#*' -and $line -match 'download\.endnote\.com') { $removedOld++; continue }
        $result.Add($line)
    }

    if (-not $Remove) {
        while ($result.Count -gt 0 -and $result[$result.Count - 1].Trim() -eq '') { $result.RemoveAt($result.Count - 1) }
        $result.Add('')
        $result.Add($MarkerStart)
        $result.Add('# EndNote auto-update blocked (EndNote-BlockUpdate.ps1)')
        $result.Add("127.0.0.1 $UpdateHost")
        $result.Add("::1 $UpdateHost")
        $result.Add($MarkerEnd)
        $result.Add('')
    } else {
        while ($result.Count -gt 0 -and $result[$result.Count - 1].Trim() -eq '') { $result.RemoveAt($result.Count - 1) }
        $result.Add('')
    }

    [System.IO.File]::WriteAllLines($path, $result.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    return $removedOld
}

function Test-HostsBlocked {
    $lines = [System.IO.File]::ReadAllLines((Get-HostsPath))
    return (($lines | Where-Object { $_ -match '^\s*127\.0\.0\.1\s+download\.endnote\.com\s*$' }).Count -gt 0)
}

# ---------- 备份 ----------
function Backup-State {
    if ($SkipBackup) { Write-Note '已按参数跳过备份。'; return $null }
    $dir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'EndNote更新拦截备份'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    Copy-Item (Get-HostsPath) (Join-Path $dir ("hosts.$stamp.bak")) -Force

    $exports = @(
        @{ Key = 'HKLM\SOFTWARE\ISI ResearchSoft\EndNote'; File = "HKLM-EndNote.$stamp.reg"; Reg = '64' },
        @{ Key = 'HKLM\SOFTWARE\WOW6432Node\ISI ResearchSoft\EndNote'; File = "HKLM-EndNote-WOW.$stamp.reg"; Reg = '32' },
        @{ Key = 'HKCU\Software\ISI ResearchSoft\EndNote\Preferences'; File = "HKCU-Preferences.$stamp.reg"; Reg = '64' }
    )
    foreach ($e in $exports) {
        $target = Join-Path $dir $e.File
        try { & reg.exe export $e.Key $target /y /reg:$($e.Reg) 2>$null | Out-Null } catch { }
    }
    return $dir
}

# ---------- 状态报告 ----------
function Show-Status {
    param([switch]$UndoMode)
    Write-Head '当前状态'

    if (Test-HostsBlocked) {
        if ($UndoMode) { Write-Caution "hosts 里仍保留着 $UpdateHost 的屏蔽（还原未完成）" }
        else { Write-Ok "hosts 已屏蔽 $UpdateHost" }
    } else {
        if ($UndoMode) { Write-Ok "hosts 已恢复：$UpdateHost 不再被指向本机" }
        else { Write-Caution "hosts 未屏蔽 $UpdateHost" }
    }

    $machine = @(Get-MachineSwitch)
    if ($machine.Count -gt 0) {
        foreach ($m in $machine) { Write-Note "HKLM $m" }
    } else {
        Write-Note 'HKLM 下未找到 EndNote 版本键（可能没装 EndNote）。'
    }

    $user = @(Get-UserPrefs)
    if ($user.Count -gt 0) { foreach ($u in $user) { Write-Note "HKCU $u" } }

    try {
        ipconfig /flushdns 2>$null | Out-Null
        $ips = @([System.Net.Dns]::GetHostAddresses($UpdateHost) | ForEach-Object { $_.IPAddressToString })
        $loopbackOnly = ($ips.Count -gt 0) -and (($ips | Where-Object { $_ -notmatch '^(127\.0\.0\.1|::1)$' }).Count -eq 0)
        if ($ips.Count -eq 0) {
            Write-Caution "$UpdateHost 解析不到地址"
        } elseif ($loopbackOnly) {
            if ($UndoMode) { Write-Caution "$UpdateHost 仍解析到本机（$($ips -join ', ')），自动更新还无法恢复。" }
            else { Write-Ok "$UpdateHost 现在解析到本机（$($ips -join ', ')），EndNote 拿不到更新清单。" }
        } else {
            if ($UndoMode) { Write-Ok "$UpdateHost 解析正常（$($ips -join ', ')），自动更新检查已恢复。" }
            else { Write-Caution "$UpdateHost 解析结果：$($ips -join ', ')（含非本机地址，屏蔽可能未生效）" }
        }
    } catch {
        Write-Caution "DNS 查询失败：$($_.Exception.Message)"
    }
}

# ================= 主流程 =================

$isAdmin = Test-IsAdmin

Write-Host 'EndNote 自动更新拦截工具' -ForegroundColor Cyan
Write-Host '（EndNote 20 / 21 / 2025，Windows）' -ForegroundColor DarkGray
Write-Host "模式：$(if ($Undo) { '解除封锁（恢复自动更新）' } else { '阻止自动更新' })"

$exePath = Get-EndNoteExe
if ($exePath) {
    Write-Note "检测到 EndNote：$exePath"
} else {
    Write-Caution '未在默认路径检测到 EndNote，仍会按规则写入（对以后安装的版本同样生效）。'
}

$endnoteRunning = @(Get-Process -Name 'EndNote' -ErrorAction SilentlyContinue)
if ($endnoteRunning.Count -gt 0) {
    Write-Caution 'EndNote 正在运行，注册表偏好要重启 EndNote 才生效；hosts 会立即生效。'
}

# 第一步：用户级偏好（对“当前登录用户”生效，不需要提权）
if (-not $AdminPhase) {
    Write-Head '用户级偏好'
    Set-UserPrefs -Enable (-not $Undo)
    if ($Undo) { Write-Ok '已移除 CheckForUpdate / UserCanApplyUpdates 标记。' }
    else { Write-Ok '已写入 CheckForUpdate = F、UserCanApplyUpdates = F。' }
}

# 第二步：需要管理员权限的部分
if (-not $isAdmin) {
    if ($NoElevate) { Write-Fail '当前不是管理员，且指定了 -NoElevate。请用管理员身份运行。'; exit 1 }
    Write-Head '申请管理员权限'
    Write-Note '修改 hosts 和 HKLM 需要管理员权限，马上会弹出用户账户控制（UAC）窗口。'

    $exe = $null
    try { $exe = (Get-Process -Id $PID).Path } catch { }
    if (-not $exe) { $exe = [Environment]::ProcessPath }
    if (-not $exe) { $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-AdminPhase')
    if ($Undo) { $argList += '-Undo' }
    if ($SkipBackup) { $argList += '-SkipBackup' }
    if ($KeepWindowOpen) { $argList += '-KeepWindowOpen' }

    try {
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList $argList -Wait -ErrorAction Stop
    } catch {
        Write-Fail '没有获得管理员权限，hosts 和 HKLM 没有改动。'
        exit 1
    }
    exit 0
}

# 管理员阶段
if (-not $SkipBackup) {
    Write-Head '备份'
    $backupDir = Backup-State
    if ($backupDir) { Write-Ok "已备份原 hosts 和注册表到：$backupDir" }
}

Write-Head 'hosts 屏蔽'
try {
    $removed = Update-HostsFile -Remove:([bool]$Undo)
    if ($Undo) {
        Write-Ok "已移除 $UpdateHost 的屏蔽。"
    } else {
        if ($removed -gt 0) { Write-Note "顺带移除了 $removed 条其它地方写的 $UpdateHost 映射，避免它们覆盖屏蔽。" }
        Write-Ok "$UpdateHost 已指向本机（IPv4 + IPv6）。"
    }
} catch {
    Write-Fail "修改 hosts 失败：$($_.Exception.Message)"
    Write-Note '常见原因：杀毒软件锁定 hosts、文件只读、权限不足。'
}

Write-Head '机器级开关'
try {
    $changed = @(Set-MachineSwitch -Value $(if ($Undo) { 'yes' } else { 'no' }))
    if ($changed.Count -eq 0) {
        Write-Caution 'HKLM 下没有找到 EndNote 版本键，跳过（hosts 屏蔽仍然有效）。'
    } else {
        foreach ($c in $changed) { Write-Ok "USERCANAPPLYUPDATES = $(if ($Undo) { 'yes' } else { 'no' })（$c）" }
    }
} catch {
    Write-Fail "写注册表失败：$($_.Exception.Message)"
}

Show-Status -UndoMode:$Undo

Write-Head '完成'
if ($Undo) {
    Write-Host '  自动更新检查已恢复。下次启动 EndNote 可能会再次提示更新。' -ForegroundColor Green
} else {
    Write-Host '  以后 EndNote 启动时不会再联网检查版本，也不会再弹更新提示。' -ForegroundColor Green
    Write-Host '  想手动升级时：先运行“一键恢复EndNote更新.cmd”，官网下载完整安装包安装，装完再运行“一键阻止EndNote更新.cmd”。' -ForegroundColor Gray
    Write-Host '  注意：重新安装或修复安装 EndNote 后，建议再运行一次本脚本。' -ForegroundColor Gray
}

if ($KeepWindowOpen -and $Host.Name -eq 'ConsoleHost') {
    Write-Host ''
    Read-Host '按回车键关闭窗口' | Out-Null
}
