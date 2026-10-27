#Requires -Version 5.1
<#
.SYNOPSIS
    阻止网盘 / 云盘软件在“此电脑”里生成图标，并清理已经生成的图标。

.DESCRIPTION
    Windows“此电脑”里的那些网盘图标，本质是注册表里的“命名空间扩展”：
        HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace
        HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace
    网盘客户端在安装 / 升级 / 启动时写入一个 CLSID 子键，资源管理器就会把它显示成图标。

    本脚本的能力：
        Scan       只扫描，不改动任何内容
        Pick       手动逐项挑选：自己决定清理哪些、保留哪些
        Clean      删除识别出的网盘图标（删除前自动备份注册表）
        Keep       查看 / 清空“手动保留名单”（挑选时保存下来的项）
        Protect    清理 + 禁止当前用户再次写入 + 注册每 N 分钟运行一次的守护任务
        Unprotect  撤销 Protect 做的加固与守护任务
        Restore    从最近的备份 .reg 恢复
        Status     查看守护任务、权限加固、当前图标数量

    省略 -Action 时显示交互菜单；清理 / 防护类操作会自动请求管理员权限。

.PARAMETER Action
    Scan | Clean | Pick | Keep | Protect | Unprotect | Restore | Status。省略时显示菜单。

.PARAMETER Keep
    保留列表，可以是 CLSID、名称或 DLL 路径的一部分。例如 -Keep 'OneDrive'。

.PARAMETER Pick
    手动逐项挑选：列出所有命名空间项并编号，由你决定清理哪些、保留哪些。
    等价于 -Action Pick。

.PARAMETER SelectIds
    配合 -Pick 使用，直接给出要清理的序号（例如 -SelectIds 1,3-5），不再交互提问。

.PARAMETER ClearKeep
    配合 -Action Keep 使用：清空“手动挑选时保存的保留名单”。

.PARAMETER AllUnknown
    把“无法确认来源的第三方项”也当作网盘图标删除。默认只删命中网盘特征的项。

.PARAMETER IncludeDesktop
    同时处理桌面命名空间（...\Explorer\Desktop\NameSpace），默认只处理“此电脑”。

.PARAMETER IntervalMinutes
    守护任务运行间隔（分钟），默认 5，最小 1。

.PARAMETER DryRun
    只显示将要做什么，不写注册表、不建任务、不改权限。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Scan -IncludeDesktop

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Protect -IntervalMinutes 3

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Unprotect

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Pick
#>
[CmdletBinding()]
param(
    [string]$Action = '',

    [string[]]$Keep = @(),

    [switch]$AllUnknown,

    [switch]$IncludeDesktop,

    [switch]$Pick,

    [string]$SelectIds = '',

    [switch]$ClearKeep,

    [switch]$DryRun,

    [switch]$Quiet,

    [int]$IntervalMinutes = 5,

    [switch]$NoGuardAcl,

    [string]$BackupRoot = (Join-Path $env:ProgramData 'NoCloudIcons\Backup'),

    [string]$InstallDir = (Join-Path $env:ProgramData 'NoCloudIcons'),

    [string]$RestoreFrom = '',

    [switch]$Scheduled,

    [switch]$Elevated
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- 常量与状态 --
$script:AppName         = '网盘图标屏蔽工具'
$script:Version         = '1.4'
$script:TaskName        = 'NoCloudIconsGuard'
$script:ScriptPath      = $PSCommandPath
$script:BoundArgs       = $PSBoundParameters
$script:QuietMode       = [bool]$Quiet
$script:UseAllUsers     = $false
$script:KeepExtra       = @()
$script:InstallDir      = $InstallDir
$script:InstalledScript = Join-Path $InstallDir 'Block-CloudIcons.ps1'
$script:StateFile       = Join-Path $InstallDir 'state.json'
$script:HistoryLog      = Join-Path $InstallDir 'history.log'
$script:GuardLog        = Join-Path $InstallDir 'guard.log'

# Windows 自带的“此电脑”项，任何情况下都不动
$script:WindowsClsid = @(
    '088e3905-0323-4b02-9826-5d99428e115f',
    '1cf1260c-4dd0-4ebb-811f-33c572699fde',
    '24ad3ad4-a569-4530-98e1-ab02f9417aa8',
    '374de290-123f-4565-9164-39c4925e467b',
    '3add1653-eb32-4cb0-bbd7-dfa0abb5acca',
    '3dfdf296-dbec-4fb4-81d1-6a3438bcf4de',
    'a0953c92-50dc-43bf-be83-3742fed03c9c',
    'a8cdff1c-4878-43be-b5fd-f8091c1c60d0',
    'b4bfcc3a-db2c-424c-b029-7fe99a87c641',
    'd3162b92-9365-467a-956b-92703aca08af',
    'f86fa3ab-70d2-4fc7-9c99-fcbf05467f3a',
    '0db7e03f-fc29-4dc6-9020-ff41b59e513a',
    # 其它常见的 Windows 自带命名空间项（桌面/此电脑里的系统入口）
    '5399e694-6ce5-4d6c-8fce-1d8870fdcba0',
    '59031a47-3f72-44a7-89c5-5595fe6b30ee',
    '031e4825-7b94-4dc3-b131-e946b44c8dd5',
    'f02c1a0d-be21-4350-88b0-7367fc96ef3c',
    '20d04fe0-3aea-1069-a2d8-08002b30309d',
    '26ee0668-a00a-44d7-9371-beb064c98683',
    '645ff040-5081-101b-9f08-00aa002f954e',
    'd20ea4e1-3957-11d2-a40b-0c5020524153'
)

# 网盘 / 云盘特征词（匹配对象：CLSID 名、默认值、显示名、DLL 路径、资源字符串）
$script:CloudRegex = '网盘|云盘|云存储|云同步|坚果云|百度网盘|百度云|阿里云盘|夸克网盘|夸克|天翼云盘|天翼云|移动云盘|移动云|联通云盘|迅雷云盘|115网盘|360云盘|微云|曲奇云盘|亿方云|燕麦云|OneDrive|SkyDrive|Dropbox|Google\s*Drive|GoogleDrive|iCloud\s*Drive|iCloudDrive|\bMEGA\b|pCloud|Nextcloud|ownCloud|Seafile|Nutstore|TeraBox|Yandex\s*Disk|MediaFire|BaiduNetdisk|BaiduYun|Aliyundrive|AliyunDrive|QuarkCloud|QuarkDrive|Weiyun|Xunlei|CloudDrive|Netdisk|PikPak|Cloudreve|Zoho\s*Drive|Amazon\s*Drive|OpenDrive'

# ------------------------------------------------------------------ 输出工具 --
function Write-Ui {
    param(
        [string]$Text = '',
        [string]$Color = 'Gray',
        [switch]$NoNewline
    )
    if ($script:QuietMode) { return }
    if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline }
    else { Write-Host $Text -ForegroundColor $Color }
}

function Get-DisplayWidth {
    # 计算字符串在控制台中的显示宽度（中日韩全角字符按 2 列计）
    param([string]$Text)
    if (-not $Text) { return 0 }
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        $wide = ($c -ge 0x1100 -and (
                $c -le 0x115F -or $c -eq 0x2329 -or $c -eq 0x232A -or
                ($c -ge 0x2E80 -and $c -le 0xA4CF -and $c -ne 0x303F) -or
                ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
                ($c -ge 0xF900 -and $c -le 0xFAFF) -or
                ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
                ($c -ge 0xFF00 -and $c -le 0xFF60) -or
                ($c -ge 0xFFE0 -and $c -le 0xFFE6) -or
                ($c -ge 0x20000 -and $c -le 0x3FFFD)))
        if ($wide) { $w += 2 } else { $w += 1 }
    }
    return $w
}

function Format-Cell {
    # 按显示宽度补空格 / 截断，保证中文列也能对齐
    param([string]$Text, [int]$Width, [string]$Align = 'Left')
    if ($null -eq $Text) { $Text = '' }
    $Text = $Text -replace '[\r\n\t]', ' '
    if ((Get-DisplayWidth $Text) -gt $Width) {
        $sb = New-Object System.Text.StringBuilder
        $w = 0
        foreach ($ch in $Text.ToCharArray()) {
            $cw = Get-DisplayWidth ([string]$ch)
            if ($w + $cw -gt $Width - 1) { break }
            [void]$sb.Append($ch)
            $w += $cw
        }
        $Text = $sb.ToString() + '…'
    }
    $pad = $Width - (Get-DisplayWidth $Text)
    if ($pad -lt 0) { $pad = 0 }
    $spaces = ' ' * $pad
    if ($Align -eq 'Right') { return $spaces + $Text }
    return $Text + $spaces
}

function Write-Table {
    param($Rows)
    if ($script:QuietMode) { return }
    if (-not $Rows) { return }
    $rows = @($Rows)
    $names = @($rows[0].PSObject.Properties.Name)
    if ($names.Count -eq 0) { return }

    $caps = @{ '位置' = 20; '标识' = 42; '名称' = 34; '判定' = 6; '依据' = 34 }
    $widths = @()
    foreach ($n in $names) {
        $w = Get-DisplayWidth $n
        foreach ($r in $rows) {
            $v = [string]$r.$n
            $vw = Get-DisplayWidth $v
            if ($vw -gt $w) { $w = $vw }
        }
        $cap = if ($caps.ContainsKey($n)) { $caps[$n] } else { 40 }
        if ($w -gt $cap) { $w = $cap }
        if ($w -lt 2) { $w = 2 }
        $widths += $w
    }

    $header = ($names | ForEach-Object -Begin { $i = 0 } -Process { $s = Format-Cell $_ $widths[$i]; $i++; $s }) -join '  '
    $line = ($widths | ForEach-Object { '-' * $_ }) -join '  '
    Write-Host ('  ' + $header.TrimEnd()) -ForegroundColor DarkCyan
    Write-Host ('  ' + $line) -ForegroundColor DarkGray
    foreach ($r in $rows) {
        $cells = @()
        for ($i = 0; $i -lt $names.Count; $i++) {
            $cells += (Format-Cell ([string]$r.($names[$i])) $widths[$i])
        }
        Write-Host ('  ' + (($cells -join '  ').TrimEnd()))
    }
}

function Write-Banner {
    if ($script:QuietMode) { return }
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
    Write-Host ('  {0}  v{1}' -f $script:AppName, $script:Version) -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
}

function Write-Log {
    param([string]$Path, [string]$Message)
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
            # 目录没能创建（未提权 / ProgramData 不可写）就放弃写日志：
            # 日志失败绝不能把非终止错误打到界面上。
            if (-not (Test-Path -LiteralPath $dir)) { return }
        }
        if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).Length -gt 512KB) {
            Move-Item -LiteralPath $Path -Destination ($Path + '.old') -Force -ErrorAction SilentlyContinue
        }
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

# ------------------------------------------------------------------ 身份判断 --
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Test-IsSystem {
    try { return [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem } catch { return $false }
}

function Get-CurrentSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Confirm-Admin {
    if (-not (Test-IsAdmin)) {
        throw '此操作需要管理员权限，请右键“以管理员身份运行”。'
    }
}

function Get-PowerShellExe {
    $p = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    try { return (Get-Process -Id $PID).Path } catch { return 'powershell.exe' }
}

function Invoke-SelfElevate {
    param([string]$ChosenAction)

    if (-not $script:ScriptPath -or -not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw '无法定位脚本自身路径，请手动以管理员身份运行本脚本。'
    }

    $exe = Get-PowerShellExe
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script:ScriptPath), '-Elevated', '-Action', $ChosenAction)

    foreach ($key in @($script:BoundArgs.Keys)) {
        if ($key -in @('Action', 'Elevated')) { continue }
        $val = $script:BoundArgs[$key]
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { $argList += ('-' + $key) }
            continue
        }
        if ($val -is [array]) {
            $argList += ('-' + $key)
            foreach ($item in $val) { $argList += ('"{0}"' -f $item) }
            continue
        }
        $argList += ('-' + $key)
        $argList += ('"{0}"' -f $val)
    }

    Write-Ui '需要管理员权限，正在请求提升……' Yellow
    try {
        $p = Start-Process -FilePath $exe -Verb RunAs -ArgumentList $argList -PassThru -ErrorAction Stop
    } catch {
        throw '提升管理员权限失败（可能取消了 UAC 提示）。请右键脚本选择“以管理员身份运行”。'
    }
    if (-not $p) { throw '未获得管理员权限。' }
    exit 0
}

# ------------------------------------------------------------ 目标键枚举/打开 --
function Get-UserSids {
    $sids = @()
    try { $sids = [Microsoft.Win32.Registry]::Users.GetSubKeyNames() } catch { return @() }
    return @($sids | Where-Object { $_ -match '^S-1-5-21-\d+-\d+-\d+-\d+$' })
}

function Get-TargetList {
    $list = New-Object System.Collections.Generic.List[object]
    $ns = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace'
    $dt = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace'

    $list.Add([pscustomobject]@{
            Label   = 'HKLM 64 位 · 此电脑'
            Hive    = 'LocalMachine'
            View    = 'Registry64'
            SubPath = $ns
            RegPath = 'HKEY_LOCAL_MACHINE\' + $ns
            Scope   = 'Machine'
        })
    $list.Add([pscustomobject]@{
            Label   = 'HKLM 32 位 · 此电脑'
            Hive    = 'LocalMachine'
            View    = 'Registry32'
            SubPath = $ns
            RegPath = 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace'
            Scope   = 'Machine'
        })

    if ($script:UseAllUsers) {
        foreach ($sid in Get-UserSids) {
            $list.Add([pscustomobject]@{
                    Label   = ('HKU {0} · 此电脑' -f $sid)
                    Hive    = 'Users'
                    View    = 'Default'
                    SubPath = ($sid + '\' + $ns)
                    RegPath = ('HKEY_USERS\{0}\{1}' -f $sid, $ns)
                    Scope   = 'User'
                })
        }
    } else {
        $list.Add([pscustomobject]@{
                Label   = 'HKCU · 此电脑'
                Hive    = 'CurrentUser'
                View    = 'Default'
                SubPath = $ns
                RegPath = 'HKEY_CURRENT_USER\' + $ns
                Scope   = 'User'
            })
    }

    if ($IncludeDesktop) {
        $list.Add([pscustomobject]@{
                Label   = 'HKLM 64 位 · 桌面'
                Hive    = 'LocalMachine'
                View    = 'Registry64'
                SubPath = $dt
                RegPath = 'HKEY_LOCAL_MACHINE\' + $dt
                Scope   = 'Machine'
            })
        $list.Add([pscustomobject]@{
                Label   = 'HKLM 32 位 · 桌面'
                Hive    = 'LocalMachine'
                View    = 'Registry32'
                SubPath = $dt
                RegPath = 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace'
                Scope   = 'Machine'
            })
        if ($script:UseAllUsers) {
            foreach ($sid in Get-UserSids) {
                $list.Add([pscustomobject]@{
                        Label   = ('HKU {0} · 桌面' -f $sid)
                        Hive    = 'Users'
                        View    = 'Default'
                        SubPath = ($sid + '\' + $dt)
                        RegPath = ('HKEY_USERS\{0}\{1}' -f $sid, $dt)
                        Scope   = 'User'
                    })
            }
        } else {
            $list.Add([pscustomobject]@{
                    Label   = 'HKCU · 桌面'
                    Hive    = 'CurrentUser'
                    View    = 'Default'
                    SubPath = $dt
                    RegPath = 'HKEY_CURRENT_USER\' + $dt
                    Scope   = 'User'
                })
        }
    }

    return $list
}

function Open-TargetKey {
    param(
        $Target,
        [switch]$Writable,
        $Rights = $null
    )

    $base = $null
    try {
        switch ($Target.Hive) {
            'LocalMachine' {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]$Target.View)
            }
            'CurrentUser' {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Default)
            }
            'Users' {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, [Microsoft.Win32.RegistryView]::Default)
            }
            default { return $null }
        }
    } catch { return $null }

    if (-not $base) { return $null }

    $key = $null
    try {
        if ($Writable) {
            $useRights = [System.Security.AccessControl.RegistryRights]::FullControl
            if ($Rights) { $useRights = $Rights }
            try {
                $key = $base.OpenSubKey($Target.SubPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $useRights)
            } catch { $key = $null }
            if (-not $key) {
                try { $key = $base.OpenSubKey($Target.SubPath, $true) } catch { $key = $null }
            }
        } else {
            $key = $base.OpenSubKey($Target.SubPath, $false)
        }
    } catch { $key = $null }
    finally { $base.Close() }

    return $key
}

function New-TargetKey {
    param($Target)
    $base = $null
    try {
        switch ($Target.Hive) {
            'LocalMachine' { $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]$Target.View) }
            'CurrentUser' { $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Default) }
            'Users' { $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, [Microsoft.Win32.RegistryView]::Default) }
            default { return $null }
        }
        if (-not $base) { return $null }
        $key = $base.CreateSubKey($Target.SubPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree)
        return $key
    } catch { return $null }
    finally { if ($base) { $base.Close() } }
}

# ---------------------------------------------------------------- CLSID 解析 --
function Get-ClsidInfo {
    param([string]$Clsid)

    $info = [pscustomobject]@{
        Clsid           = $Clsid
        Display         = ''
        LocalizedString = ''
        Dll             = ''
        ProductName     = ''
        DefaultIcon     = ''
        HasShell        = $false
        HasInstance     = $false
        InHKCU          = $false
        InHKLM          = $false
        Found           = $false
    }

    # 只注册在 HKCU\Software\Classes 下的 CLSID，基本都是第三方安装器自己写的
    $inHkcu = 'Registry::HKEY_CURRENT_USER\Software\Classes\CLSID\' + $Clsid
    $info.InHKCU = (Test-Path -LiteralPath $inHkcu)
    $info.InHKLM = ((Test-Path -LiteralPath ('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\CLSID\' + $Clsid)) -or
                    (Test-Path -LiteralPath ('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\WOW6432Node\CLSID\' + $Clsid)))

    $bases = @(
        ('Registry::HKEY_CLASSES_ROOT\CLSID\' + $Clsid),
        ('Registry::HKEY_CLASSES_ROOT\WOW6432Node\CLSID\' + $Clsid),
        $inHkcu
    )

    foreach ($base in $bases) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $info.Found = $true

        try {
            $k = Get-Item -LiteralPath $base -ErrorAction Stop
            $v = [string]$k.GetValue('', '')
            if ($v -and -not $info.Display) { $info.Display = $v }
            $k.Close()
        } catch { }

        foreach ($sub in @('InprocServer32', 'LocalServer32')) {
            $p = $base + '\' + $sub
            if (-not (Test-Path -LiteralPath $p)) { continue }
            try {
                $k = Get-Item -LiteralPath $p -ErrorAction Stop
                $v = [string]$k.GetValue('', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $k.Close()
                if ($v) {
                    $v = $v.Trim().Trim('"')
                    $v = $v -replace '^\\\\\?\\', ''
                    if (-not $info.Dll) { $info.Dll = $v }
                }
            } catch { }
        }

        # 图标文件往往直接暴露厂商和安装目录，例如 D:\BaiduNetdisk\netdisk_logo.ico
        $p = $base + '\DefaultIcon'
        if (Test-Path -LiteralPath $p) {
            try {
                $k = Get-Item -LiteralPath $p -ErrorAction Stop
                $v = [string]$k.GetValue('', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $k.Close()
                if ($v -and -not $info.DefaultIcon) {
                    $v = $v.Trim().Trim('"')
                    $info.DefaultIcon = ($v -split ',')[0].Trim()
                }
            } catch { }
        }

        if (Test-Path -LiteralPath ($base + '\Shell')) { $info.HasShell = $true }
        if (Test-Path -LiteralPath ($base + '\Instance')) { $info.HasInstance = $true }

        $p = $base + '\ShellFolder'
        if (Test-Path -LiteralPath $p) {
            try {
                $k = Get-Item -LiteralPath $p -ErrorAction Stop
                $v = [string]$k.GetValue('LocalizedString', '')
                $k.Close()
                if ($v -and -not $info.LocalizedString) { $info.LocalizedString = $v }
            } catch { }
        }
    }

    if ($info.Dll) {
        try { $info.Dll = [Environment]::ExpandEnvironmentVariables($info.Dll) } catch { }
        if (Test-Path -LiteralPath $info.Dll) {
            try {
                $vi = (Get-Item -LiteralPath $info.Dll -ErrorAction Stop).VersionInfo
                if ($vi) {
                    if ($vi.ProductName) { $info.ProductName = $vi.ProductName.Trim() }
                    elseif ($vi.FileDescription) { $info.ProductName = $vi.FileDescription.Trim() }
                }
            } catch { }
        }
    }

    return $info
}

# ------------------------------------------------------------------ 条目读取 --
function Test-IsSystemDll {
    param([string]$Dll)
    if (-not $Dll) { return $false }
    $root = $env:SystemRoot.TrimEnd('\')
    if ($Dll -like ($root + '\*')) { return $true }
    if ($Dll -like '%SystemRoot%*' -or $Dll -like '%windir%*') { return $true }
    return $false
}

function Get-Entries {
    param($Target)

    $result = New-Object System.Collections.Generic.List[object]
    $root = Open-TargetKey -Target $Target
    if (-not $root) { return $result }

    $names = @()
    try { $names = @($root.GetSubKeyNames()) } catch { $names = @() }

    foreach ($name in $names) {
        if ($name -eq 'DelegateFolders') { continue }

        $default = ''
        $sub = $null
        try {
            $sub = $root.OpenSubKey($name, $false)
            if ($sub) { $default = [string]$sub.GetValue('', '') }
        } catch { }
        finally { if ($sub) { $sub.Close() } }

        $info = Get-ClsidInfo -Clsid $name

        # 显示名优先级：命名空间键里的默认值（网盘一般直接写“百度网盘”）
        # > ShellFolder 本地化字符串 > CLSID 默认值 > DLL 的版本信息
        $display = ''
        if ($default -and $default -notlike 'CLSID_*' -and $default -notlike '@*') { $display = $default }
        elseif ($info.LocalizedString -and $info.LocalizedString -notlike '@*') { $display = $info.LocalizedString }
        elseif ($info.Display -and $info.Display -notlike '@*' -and $info.Display -notlike 'CLSID_*') { $display = $info.Display }
        elseif ($info.ProductName) { $display = $info.ProductName }

        # 判定用的“证据串”：把能暴露身份的东西全放进来（含图标路径、CLSID 默认值）
        $haystack = @($name, $default, $info.Display, $info.DefaultIcon, $info.Dll, $info.LocalizedString, $info.ProductName) -join ' '

        # 第三方痕迹：只要命中任意一条，就说明这个命名空间项是外部软件写的，
        # 不能被“DLL 在 C:\Windows 里”当成系统组件豁免（网盘常用 shdocvw.dll 当宿主）。
        $icon = $info.DefaultIcon
        if ($icon) { $icon = [Environment]::ExpandEnvironmentVariables($icon) }
        $iconOutside = $false
        if ($icon -and ($icon -match '^[A-Za-z]:\\' -or $icon -match '^\\\\')) {
            $iconOutside = -not (Test-IsSystemDll -Dll $icon)
        }

        $thirdParty = @()
        if ($iconOutside) { $thirdParty += '图标不在系统目录' }
        if ($default -and $default -notlike 'CLSID_*') { $thirdParty += '命名项有自定义名称' }
        if ($info.InHKCU -and -not $info.InHKLM) { $thirdParty += '只注册在 HKCU' }
        if ($info.Dll -and -not (Test-IsSystemDll -Dll $info.Dll)) { $thirdParty += 'DLL 不在系统目录' }

        # 强证据：能单凭它断定“不是 Windows 自带项”。
        # “自定义名称”只在“此电脑”位置才算强证据 —— 桌面上的系统文件夹
        # （文档 / 搜索 / CSC 等）在 Desktop\NameSpace 里也带默认显示名。
        $isThisPC = ($Target.SubPath -like '*\MyComputer\NameSpace')
        $strong = @()
        if ($iconOutside) { $strong += '图标不在系统目录' }
        if ($isThisPC -and $default -and $default -notlike 'CLSID_*') { $strong += '命名项有自定义名称' }
        if ($info.InHKCU -and -not $info.InHKLM) { $strong += '只注册在 HKCU' }
        if ($info.Dll -and -not (Test-IsSystemDll -Dll $info.Dll)) { $strong += 'DLL 不在系统目录' }

        $result.Add([pscustomobject]@{
                Target     = $Target
                Name       = $name
                Default    = $default
                Display    = $display
                Dll        = $info.Dll
                Product    = $info.ProductName
                Localized  = $info.LocalizedString
                DefaultIcon = $info.DefaultIcon
                InHKCU     = $info.InHKCU
                HasShell   = $info.HasShell
                SystemDll  = (Test-IsSystemDll -Dll $info.Dll)
                ThirdParty = @($thirdParty)
                Strong     = @($strong)
                IsThisPC   = $isThisPC
                Haystack   = $haystack
                Verdict    = ''
                Reason     = ''
                Result     = ''
            })
    }

    try { $root.Close() } catch { }
    return $result
}

function Test-KeepHit {
    param($Entry)
    foreach ($k in $Keep) {
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        if ($Entry.Name -like ('*' + $k + '*')) { return ('保留列表：' + $k) }
        if ($Entry.Display -like ('*' + $k + '*')) { return ('保留列表：' + $k) }
        if ($Entry.Dll -like ('*' + $k + '*')) { return ('保留列表：' + $k) }
        if ($Entry.Product -like ('*' + $k + '*')) { return ('保留列表：' + $k) }
    }

    # 手动挑选时保存下来的保留名单（state.json 里的 KeepExtra），守护任务也遵守
    foreach ($k in $script:KeepExtra) {
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        if ($Entry.Name -eq $k) { return ('手动保留：' + $k) }
    }

    return ''
}

function Resolve-Verdict {
    param($Entry)

    $keepHit = Test-KeepHit -Entry $Entry
    if ($keepHit) { return [pscustomobject]@{ Verdict = 'Keep'; Reason = $keepHit } }

    $bare = $Entry.Name.Trim('{', '}').ToLower()
    if ($script:WindowsClsid -contains $bare) {
        return [pscustomobject]@{ Verdict = 'Keep'; Reason = 'Windows 内置项' }
    }

    # 关键词判定必须排在“系统 DLL”之前：百度网盘这类软件是用 shdocvw.dll、
    # shell32.dll 这些系统 DLL 当 IShellFolder 宿主的，按 DLL 位置判断会漏。
    if ($Entry.Haystack -match $script:CloudRegex) {
        return [pscustomobject]@{ Verdict = 'Delete'; Reason = '命中网盘关键词' }
    }

    $traces = @($Entry.Strong | Where-Object { $_ })

    # 只有“带系统 DLL、且没有任何强第三方证据”才算系统组件
    if ($traces.Count -eq 0 -and $Entry.SystemDll) {
        return [pscustomobject]@{ Verdict = 'Keep'; Reason = '系统组件（C:\Windows）' }
    }

    if ($traces.Count -gt 0) {
        $why = $traces[0]
        if ($traces.Count -gt 1) { $why = $why + ' 等' }

        if ($Entry.IsThisPC) {
            return [pscustomobject]@{ Verdict = 'Delete'; Reason = '第三方命名空间：' + $why }
        }

        if ($AllUnknown) {
            return [pscustomobject]@{ Verdict = 'Delete'; Reason = '非系统项（-AllUnknown）' }
        }

        return [pscustomobject]@{ Verdict = 'Unknown'; Reason = '此电脑之外的第三方项，未删' }
    }

    if ($AllUnknown) {
        return [pscustomobject]@{ Verdict = 'Delete'; Reason = '非系统项（-AllUnknown）' }
    }

    return [pscustomobject]@{ Verdict = 'Unknown'; Reason = '来源不明，未删（可用 -AllUnknown）' }
}

function Get-AllEntries {
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($t in Get-TargetList) {
        $entries = Get-Entries -Target $t
        foreach ($e in $entries) {
            $v = Resolve-Verdict -Entry $e
            $e.Verdict = $v.Verdict
            $e.Reason = $v.Reason
            $all.Add($e)
        }
    }
    return @($all.ToArray())
}

function Format-EntryRow {
    param($Entry)
    $judge = switch ($Entry.Verdict) {
        'Delete' { '删除' }
        'Keep' { '保留' }
        'Unknown' { '未知' }
        default { $Entry.Verdict }
    }
    [pscustomobject]@{
        '位置' = $Entry.Target.Label
        '标识' = $Entry.Name
        '名称' = $(if ($Entry.Display) { $Entry.Display } else { '—' })
        '判定' = $judge
        '依据' = $Entry.Reason
    }
}

function Write-EntryRows {
    param($Entries)
    if (-not $Entries) { return }
    Write-Table ($Entries | ForEach-Object { Format-EntryRow -Entry $_ })
}

# ------------------------------------------------------------ 备份 / 删除 / 刷新 --
function New-BackupDirectory {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $BackupRoot $stamp
    $i = 1
    while (Test-Path -LiteralPath $dir) {
        $dir = Join-Path $BackupRoot ('{0}-{1}' -f $stamp, $i)
        $i++
    }
    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        New-Item -ItemType Directory -Path $BackupRoot -Force -ErrorAction SilentlyContinue | Out-Null
    }
    New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    return $dir
}

function Export-RegKey {
    param([string]$RegPath, [string]$Directory)

    $safe = ($RegPath -replace '[\\/:*?"<>|]', '_')
    $file = Join-Path $Directory ($safe + '.reg')
    try {
        $output = & reg.exe export $RegPath $file /y 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Ui ('  备份失败：{0}' -f $RegPath) Yellow
            return $null
        }
    } catch {
        Write-Ui ('  备份失败：{0}（{1}）' -f $RegPath, $_.Exception.Message) Yellow
        return $null
    }
    return $file
}

function Remove-OldBackups {
    param([int]$KeepCount = 20)
    if (-not (Test-Path -LiteralPath $BackupRoot)) { return }
    $dirs = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($dirs.Count -le $KeepCount) { return }
    $dirs | Select-Object -Skip $KeepCount | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-Entry {
    param($Entry)

    $parent = Open-TargetKey -Target $Entry.Target -Writable
    if (-not $parent) {
        Write-Ui ('  无法打开（权限不足）：{0}' -f $Entry.Target.RegPath) Yellow
        return $false
    }
    try {
        $parent.DeleteSubKeyTree($Entry.Name, $false)
        return $true
    } catch {
        Write-Ui ('  删除失败 {0}\{1}：{2}' -f $Entry.Target.RegPath, $Entry.Name, $_.Exception.Message) Yellow
        return $false
    } finally {
        try { $parent.Close() } catch { }
    }
}

function Refresh-Explorer {
    try {
        if (-not ('ShellNotify.NativeMethods' -as [type])) {
            Add-Type -Namespace ShellNotify -Name NativeMethods -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto, SetLastError = true)]
public static extern void SHChangeNotify(int eventId, int flags, System.IntPtr item1, System.IntPtr item2);
'@ -ErrorAction Stop
        }
        [ShellNotify.NativeMethods]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)
    } catch { }
}

# ------------------------------------------------------------------ 权限加固 --
function Get-AclRights {
    return ([System.Security.AccessControl.RegistryRights]::ReadPermissions -bor [System.Security.AccessControl.RegistryRights]::ChangePermissions)
}

function Get-CreateSubKeyDenyRules {
    # 找出“拒绝创建子键”的显式 ACE（只找显式的，不动继承来的）
    param($Acl, [string]$Sid)

    $found = New-Object System.Collections.ArrayList
    if (-not $Acl) { return $found }
    foreach ($rule in @($Acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
        if ($rule.AccessControlType -ne 'Deny') { continue }
        # 用按位判断而不是相等判断：万一有哪一版把 CreateSubKey 和其它权限合在一起加，也要认得出来
        if (-not ($rule.RegistryRights -band [System.Security.AccessControl.RegistryRights]::CreateSubKey)) { continue }
        if ($rule.IdentityReference.Value -ne $Sid) { continue }
        [void]$found.Add($rule)
    }
    return $found
}

function Add-CreateSubKeyDeny {
    param($Target, [string]$Sid)

    $key = Open-TargetKey -Target $Target -Writable -Rights (Get-AclRights)
    if (-not $key) { $key = New-TargetKey -Target $Target }
    if (-not $key) { return $false }

    try {
        $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)

        if (@(Get-CreateSubKeyDenyRules -Acl $acl -Sid $Sid).Count -gt 0) {
            return $true   # 已经加固过
        }

        $newRule = New-Object System.Security.AccessControl.RegistryAccessRule(
            (New-Object System.Security.Principal.SecurityIdentifier($Sid)),
            [System.Security.AccessControl.RegistryRights]::CreateSubKey,
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Deny
        )
        $acl.AddAccessRule($newRule)
        $key.SetAccessControl($acl)
        return $true
    } catch {
        Write-Ui ('  加固失败：{0}（{1}）' -f $Target.RegPath, $_.Exception.Message) Yellow
        return $false
    } finally {
        try { $key.Close() } catch { }
    }
}

function New-AclWithoutCreateSubKeyDeny {
    # 复制一份 ACL，去掉“拒绝创建子键”的显式 ACE（其它显式规则原样保留，继承关系不动）。
    # 抽出来单独一份是为了能脱离注册表做单元测试（写 ACL 需要管理员权限，测试跑不了）。
    param($Acl, [string]$Sid)

    $fresh = New-Object System.Security.AccessControl.RegistrySecurity
    if ($Acl) {
        $fresh.SetAccessRuleProtection($Acl.AreAccessRulesProtected, $false)
        foreach ($rule in @($Acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
            if ($rule.AccessControlType -eq 'Deny' -and
                ($rule.RegistryRights -band [System.Security.AccessControl.RegistryRights]::CreateSubKey) -and
                $rule.IdentityReference.Value -eq $Sid) { continue }
            $fresh.AddAccessRule($rule)
        }
    }
    return ,$fresh
}

function Remove-CreateSubKeyDeny {
    # 返回值：-1 = 打不开键（权限不够）；0 = 本来就没有；>0 = 删掉了几条
    param($Target, [string]$Sid)

    $key = Open-TargetKey -Target $Target -Writable -Rights (Get-AclRights)
    if (-not $key) { return -1 }

    $removed = 0
    try {
        $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
        $rules = @(Get-CreateSubKeyDenyRules -Acl $acl -Sid $Sid)
        $hadRules = $rules.Count
        if ($hadRules -eq 0) { return 0 }

        # 主路径：在同一个 ACL 对象上删掉这几条，然后再写回。
        # 注意 RemoveAccessRuleSpecific() 返回 void，不能拿返回值当判断条件。
        foreach ($rule in $rules) {
            try { $acl.RemoveAccessRuleSpecific($rule) } catch { }
        }

        if (@(Get-CreateSubKeyDenyRules -Acl $acl -Sid $Sid).Count -eq 0) {
            $key.SetAccessControl($acl)
        } else {
            # 兜底路径：整份 DACL 重写（保留其它显式规则，继承关系不动）
            $key.SetAccessControl((New-AclWithoutCreateSubKeyDeny -Acl $acl -Sid $Sid))
        }
        $removed = $hadRules
    } catch {
        Write-Ui ('  解除加固失败：{0}（{1}）' -f $Target.RegPath, $_.Exception.Message) Yellow
        return -1
    } finally {
        try { $key.Close() } catch { }
    }
    return $removed
}

function Test-CreateSubKeyDeny {
    param($Target, [string]$Sid)

    $key = Open-TargetKey -Target $Target
    if (-not $key) { return $false }
    $found = $false
    try {
        $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
        $found = (@(Get-CreateSubKeyDenyRules -Acl $acl -Sid $Sid).Count -gt 0)
    } catch { } finally { try { $key.Close() } catch { } }
    return $found
}

function Get-TargetAclDump {
    # 诊断用：把目标键的 DACL 打印出来，便于判断“拒绝规则到底是谁加的”
    param($Target)

    $key = Open-TargetKey -Target $Target
    if (-not $key) { return '（无法读取该键的权限）' }
    try {
        $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
        $lines = @()
        $lines += 'SDDL: ' + $acl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
        foreach ($rule in @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
            $lines += ('显式：{0} {1} {2}' -f $rule.AccessControlType, $rule.IdentityReference.Value, $rule.RegistryRights)
        }
        return ($lines -join "`r`n")
    } catch {
        return ('（读取权限失败：{0}）' -f $_.Exception.Message)
    } finally { try { $key.Close() } catch { } }
}

function Get-UserNamespaceTargets {
    return @(Get-TargetList | Where-Object { $_.Hive -eq 'CurrentUser' })
}

# ------------------------------------------------------------------ 守护任务 --
function Get-GuardCommandPath {
    return (Join-Path $InstallDir 'run-guard.cmd')
}

function Write-GuardLauncher {
    # 守护任务通过这个小 .cmd 启动 PowerShell：路径里有空格或中文都不会踩引号问题，
    # 出问题时也可以手动双击跑一下看看行为。
    $path = Get-GuardCommandPath
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        throw ('无法创建目录：{0}（需要管理员权限）' -f $InstallDir)
    }
    $exe = Get-PowerShellExe
    $body = '"{0}" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Action Clean -Quiet -Scheduled' -f $exe, $script:InstalledScript
    $text = "@echo off`r`n$body`r`n"
    [System.IO.File]::WriteAllText($path, $text, [System.Text.Encoding]::Default)
    return $path
}

function Install-GuardTask {
    # 不用 ScheduledTasks 模块的 XML 注册：它把“重复持续时间”写成 P99999999DT23H59M59S，
    # 本机任务计划直接拒收（"The task XML contains a value which is incorrectly formatted or out of range"）。
    # 改用 schtasks 命令行，由 Windows 自己生成任务定义，不会再踩这个坑。
    $cmdPath = Write-GuardLauncher

    $minutes = [int]$IntervalMinutes
    if ($minutes -lt 1) { $minutes = 1 }
    if ($minutes -gt 1439) { $minutes = 1439 }

    $output = @(& schtasks.exe /Create /TN $script:TaskName /TR $cmdPath /SC MINUTE /MO $minutes /RU 'SYSTEM' /RL HIGHEST /F 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $msg = (@($output) -join ' ').Trim()
        if (-not $msg) { $msg = 'schtasks 返回 ' + $LASTEXITCODE }
        throw ('注册计划任务失败：{0}' -f $msg)
    }
}

function Uninstall-GuardTask {
    $existed = $false
    $output = @(& schtasks.exe /Delete /TN $script:TaskName /F 2>&1)
    if ($LASTEXITCODE -eq 0) {
        $existed = $true
    } else {
        # 任务本来就不存在时 schtasks 也返回非 0，这不算失败
        $joined = (@($output) -join ' ')
        if ($joined -notmatch '找不到|does not exist|cannot find') {
            $msg = $joined.Trim()
            if ($msg) { Write-Ui ('   删除守护任务时返回：{0}' -f $msg) DarkGray }
        }
    }

    $cmdPath = Get-GuardCommandPath
    if (Test-Path -LiteralPath $cmdPath) {
        Remove-Item -LiteralPath $cmdPath -Force -ErrorAction SilentlyContinue
    }
    return $existed
}

function Get-GuardTaskInfo {
    $info = [pscustomobject]@{
        Exists   = $false
        State    = ''
        LastRun  = $null
        NextRun  = $null
        Interval = ''
        Task     = $null
    }

    # 用 schtasks /Query /XML 判断存在性与间隔：输出与系统语言无关，比 CIM 稳
    $raw = @(& schtasks.exe /Query /TN $script:TaskName /XML 2>&1)
    if ($LASTEXITCODE -ne 0) { return $info }
    $xml = @($raw) -join "`n"
    if ($xml -notmatch '<Task') { return $info }

    $info.Exists = $true
    if ($xml -match '<Interval>([^<]+)</Interval>') { $info.Interval = $Matches[1] }
    $info.State = '已注册'

    # 状态、上次/下次运行时间靠 CIM 补（拿不到就留空，不影响其它功能）
    try {
        $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
        if ($task) {
            $info.Task = $task
            if ($task.State) { $info.State = [string]$task.State }
        }
        $ti = Get-ScheduledTaskInfo -TaskName $script:TaskName -ErrorAction Stop
        if ($ti) {
            $info.LastRun = $ti.LastRunTime
            $info.NextRun = $ti.NextRunTime
        }
    } catch { }

    return $info
}

# -------------------------------------------------------------------- 状态文件 --
function Save-State {
    param($AclRecords)
    try {
        if (-not (Test-Path -LiteralPath $InstallDir)) {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        }
        $state = [pscustomobject]@{
            Version         = $script:Version
            InstalledAt     = (Get-Date).ToString('s')
            ScriptPath      = $script:InstalledScript
            TaskName        = $script:TaskName
            IntervalMinutes = $IntervalMinutes
            GuardAcl        = @($AclRecords)
            BackupRoot      = $BackupRoot
            KeepExtra       = @($script:KeepExtra)
        }
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
    } catch {
        Write-Ui ('  保存状态失败：{0}' -f $_.Exception.Message) Yellow
    }
}

function Get-State {
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return $null }
    try {
        return (Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch { return $null }
}

# -------------------------------------------------------------------- 各操作 --
function Invoke-Scan {
    $rows = @(Get-AllEntries)
    $delete = @($rows | Where-Object { $_.Verdict -eq 'Delete' })
    $unknown = @($rows | Where-Object { $_.Verdict -eq 'Unknown' })
    $kept = @($rows | Where-Object { $_.Verdict -eq 'Keep' })

    Write-Ui ''
    Write-Ui ('扫描范围：' + (($rows | ForEach-Object { $_.Target.Label } | Sort-Object -Unique) -join '、')) Cyan
    if (-not $rows) {
        Write-Ui '这些位置目前没有命名空间项。' Gray
        return
    }

    Write-Ui ('合计 {0} 项：网盘图标 {1} 个，来源不明 {2} 个，系统/保留 {3} 个。' -f $rows.Count, $delete.Count, $unknown.Count, $kept.Count)
    Write-Ui ''

    if ($delete.Count -gt 0) {
        Write-Ui '【可清理的网盘图标】' Green
        Write-EntryRows $delete
        foreach ($e in $delete) {
            if ($e.Dll) { Write-Ui ('   {0}  ->  {1}' -f $e.Name, $e.Dll) DarkGray }
        }
        Write-Ui ''
    }

    if ($unknown.Count -gt 0) {
        Write-Ui '【来源不明的第三方项（默认不处理）】' Yellow
        Write-EntryRows $unknown
        Write-Ui '   确认它们也是网盘图标后，可加 -AllUnknown 一并清理。' DarkGray
        Write-Ui ''
    }

    if ($kept.Count -gt 0) {
        Write-Ui ('【系统项 / 保留项】共 {0} 个，未列出。' -f $kept.Count) DarkGray
        Write-Ui ''
    }

    if ($delete.Count -eq 0 -and $unknown.Count -eq 0) {
        Write-Ui '没有发现网盘图标。' Green
    }
}

function Remove-SelectedEntries {
    # 备份 + 删除给定的条目集合（不打印清单、不确认，由调用者决定清理哪些）
    param($Targets)

    $list = @($Targets)
    $backupDir = New-BackupDirectory
    if (-not $backupDir) {
        # 没有备份就不删除：宁可留图标，也要保证能回滚
        if (-not $script:QuietMode) {
            Write-Ui '无法创建备份目录，已放弃本次清理（没有备份就不删除，避免不可恢复）。' Yellow
            Write-Ui ('   请检查这个目录的写权限：{0}' -f $BackupRoot) DarkGray
        }
        return [pscustomobject]@{
            Removed   = 0
            Failed    = 0
            Skipped   = $list.Count
            BackupDir = $null
            Summary   = ('备份目录不可用，本次未做任何改动（{0} 项待清理）' -f $list.Count)
        }
    }

    $exported = @{}
    foreach ($e in $list) {
        $rp = $e.Target.RegPath
        if ($exported.ContainsKey($rp)) { continue }
        $file = Export-RegKey -RegPath $rp -Directory $backupDir
        $exported[$rp] = $file
        if ($file) { Write-Ui ('  已备份 {0}' -f $rp) DarkGray }
    }

    $removed = 0
    $failed = 0
    $skipped = 0
    $manifest = @()
    foreach ($e in $list) {
        $file = $exported[$e.Target.RegPath]
        if (-not $file) {
            # 备份失败的键一律不动，保证可回滚
            $skipped++
            $manifest += [pscustomobject]@{
                '位置' = $e.Target.Label
                'CLSID' = $e.Name
                '名称' = $e.Display
                'DLL' = $e.Dll
                '依据' = $e.Reason
                '结果' = '跳过（备份失败）'
            }
            continue
        }
        $ok = Remove-Entry -Entry $e
        if ($ok) { $removed++ } else { $failed++ }
        $manifest += [pscustomobject]@{
            '位置' = $e.Target.Label
            'CLSID' = $e.Name
            '名称' = $e.Display
            'DLL' = $e.Dll
            '依据' = $e.Reason
            '结果' = $(if ($ok) { '已删除' } else { '失败' })
        }
    }

    try {
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupDir 'manifest.json') -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }

    Refresh-Explorer | Out-Null
    Remove-OldBackups -KeepCount 20 | Out-Null

    $summary = '清理完成：删除 {0} 个，失败 {1} 个，跳过 {2} 个；备份目录 {3}' -f $removed, $failed, $skipped, $backupDir
    Write-Ui $summary Green
    if ($failed -gt 0) { Write-Ui '   部分项目删除失败，通常是权限不足或该项被系统保护。' Yellow }
    if ($skipped -gt 0) { Write-Ui '   有项目因备份失败被跳过（未改动），可稍后重试。' Yellow }

    return [pscustomobject]@{
        Removed   = $removed
        Failed    = $failed
        Skipped   = $skipped
        BackupDir = $backupDir
        Summary   = $summary
    }
}

function Invoke-Clean {
    $rows = @(Get-AllEntries)
    $targets = @($rows | Where-Object { $_.Verdict -eq 'Delete' })

    if ($targets.Count -eq 0) {
        if (-not $script:QuietMode) { Write-Ui '没有需要清理的网盘图标。' Green }
        return 0
    }

    if (-not $script:QuietMode) {
        Write-Ui ('准备清理 {0} 个网盘图标：' -f $targets.Count) Green
        Write-EntryRows $targets
        Write-Ui ''
        Write-Ui '   只想删其中一部分？用 -Pick（菜单里的“手动挑选”）。' DarkGray
        Write-Ui ''
    }

    if ($DryRun) {
        Write-Ui '（DryRun：仅演示，未修改注册表）' Yellow
        return 0
    }

    if (-not $Scheduled) { Confirm-Admin }

    $out = Remove-SelectedEntries -Targets $targets

    Write-Log -Path $script:HistoryLog -Message $out.Summary
    if ($Scheduled) { Write-Log -Path $script:GuardLog -Message $out.Summary }

    return $out.Removed
}

# ------------------------------------------------------- 手动挑选 / 保留名单 --
function ConvertTo-SelectionIndexes {
    # 解析 “1,3-5、7” 这类输入，返回从 1 开始的序号数组；无法解析返回 $null
    param([string]$Text, [int]$Max)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $set = New-Object 'System.Collections.Generic.SortedSet[int]'
    foreach ($part in ($Text -split '[,\s;、，]+')) {
        if (-not $part) { continue }

        if ($part -match '^(\d+)\s*[-~]\s*(\d+)$') {
            $a = [int]$Matches[1]
            $b = [int]$Matches[2]
            if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
            if ($a -lt 1 -or $b -gt $Max) { return $null }
            for ($i = $a; $i -le $b; $i++) { [void]$set.Add($i) }
            continue
        }

        if ($part -match '^\d+$') {
            $i = [int]$part
            if ($i -lt 1 -or $i -gt $Max) { return $null }
            [void]$set.Add($i)
            continue
        }

        return $null
    }

    if ($set.Count -eq 0) { return $null }
    return @($set)
}

function Format-PickRow {
    param($Entry, [int]$Index)
    $judge = switch ($Entry.Verdict) {
        'Delete' { '待清理' }
        'Keep' { '系统项' }
        'Unknown' { '未知' }
        default { $Entry.Verdict }
    }
    [pscustomobject]@{
        '序号' = [string]$Index
        '位置' = $Entry.Target.Label
        '标识' = $Entry.Name
        '名称' = $(if ($Entry.Display) { $Entry.Display } else { '—' })
        '判定' = $judge
        '依据' = $Entry.Reason
    }
}

function Select-EntriesInteractive {
    # 列出可挑选项并编号（编号只对应“当前显示的清单”）；返回 Selected + Candidates
    param($Entries, [string]$AutoSelect = '')

    $empty = [pscustomobject]@{ Selected = @(); Candidates = @() }
    $list = @($Entries)
    if ($list.Count -eq 0) { return $empty }

    $candidates = @($list | Where-Object { $_.Verdict -ne 'Keep' })
    $showAll = ($candidates.Count -eq 0)
    $autoText = [string]$AutoSelect
    $autoMode = (-not [string]::IsNullOrWhiteSpace($autoText))

    Write-Ui ''
    if ($candidates.Count -gt 0) {
        Write-Ui ('共扫描到 {0} 项：下面列出 {1} 个“待清理 / 来源不明”的项，另有 {2} 个系统项（输入 a 可一起查看）。' -f $list.Count, $candidates.Count, ($list.Count - $candidates.Count)) Cyan
    } else {
        Write-Ui ('共扫描到 {0} 项，全部是系统项。输入 a 可以连系统项一起查看、强行挑选。' -f $list.Count) Yellow
    }

    $selected = @()
    while ($true) {
        $visible = @()
        foreach ($e in $list) {
            if ($showAll -or $e.Verdict -ne 'Keep') { $visible += $e }
        }

        $rows = @()
        for ($k = 0; $k -lt $visible.Count; $k++) {
            $rows += (Format-PickRow -Entry $visible[$k] -Index ($k + 1))
        }

        Write-Ui ''
        if ($rows.Count -gt 0) { Write-Table $rows }
        Write-Ui ''
        Write-Ui '按上面的序号清理（例：1,3-5）；all 全选；none 全不选；a 显示/隐藏系统项；q 取消。' DarkGray

        $fromAuto = $false
        if ($autoMode) {
            $text = $autoText
            $autoMode = $false
            $fromAuto = $true
            Write-Ui ('  已按 -SelectIds 自动选择：' + $text) DarkGray
        } else {
            if ($Host.Name -ne 'ConsoleHost' -or $script:QuietMode) {
                Write-Ui '  当前不是交互式控制台：请加 -SelectIds "1,3" 指定序号后再运行。' Yellow
                return $empty
            }
            $text = [string](Read-Host '请输入')
            if ([string]::IsNullOrWhiteSpace($text)) {
                Write-Ui '未输入内容，已取消。' Green
                return $empty
            }
        }

        $t = $text.Trim().ToLower()
        if ($t -eq 'q') {
            Write-Ui '已取消，未做改动。' Green
            return $empty
        }
        if ($t -eq 'a') { $showAll = -not $showAll; continue }
        if ($t -eq 'none') { $selected = @(); break }
        if ($t -eq 'all') { $selected = @($visible); break }

        $idx = ConvertTo-SelectionIndexes -Text $text -Max $visible.Count
        if ($null -eq $idx) {
            Write-Ui ('  输入无法识别：请按 “1,3-5” 的格式输入（序号范围 1-{0}）。' -f $visible.Count) Yellow
            if ($fromAuto) { return $empty }
            continue
        }
        $selected = @($idx | ForEach-Object { $visible[$_ - 1] })
        break
    }

    $selected = @($selected | Where-Object { $_ })
    if ($selected.Count -eq 0) {
        Write-Ui '没有选中任何项，未做改动。' Green
        return [pscustomobject]@{ Selected = @(); Candidates = $candidates }
    }

    Write-Ui ''
    Write-Ui ('已选择 {0} 项：' -f $selected.Count) Green
    Write-EntryRows $selected
    Write-Ui ''

    $sys = @($selected | Where-Object { $_.Verdict -eq 'Keep' })
    if ($sys.Count -gt 0) {
        Write-Ui ('注意：其中 {0} 项本来是系统项，删掉后资源管理器里对应的入口会消失（可用 -Action Restore 恢复）。' -f $sys.Count) Yellow
    }

    if ([string]::IsNullOrWhiteSpace($AutoSelect) -and $Host.Name -eq 'ConsoleHost' -and -not $script:QuietMode) {
        $ans = [string](Read-Host '确认清理以上项？(Y/n)')
        if ($ans -and ($ans.Trim().ToLower() -in @('n', 'no', 'q'))) {
            Write-Ui '已取消。' Yellow
            return [pscustomobject]@{ Selected = @(); Candidates = $candidates }
        }
    }

    return [pscustomobject]@{ Selected = @($selected); Candidates = $candidates }
}

function Add-StateKeep {
    # 把项目加入“手动保留名单”（state.json 的 KeepExtra），返回新增加的条数
    param([string[]]$Items)

    $clean = @()
    foreach ($i in $Items) {
        if ([string]::IsNullOrWhiteSpace($i)) { continue }
        if ($clean -notcontains $i) { $clean += $i }
    }
    if ($clean.Count -eq 0) { return 0 }

    $st = Get-State
    $list = @()
    if ($st -and ($st.PSObject.Properties.Name -contains 'KeepExtra')) { $list = @($st.KeepExtra) }

    $added = 0
    foreach ($i in $clean) {
        if ($list -notcontains $i) { $list += $i; $added++ }
    }
    if ($added -eq 0) { return 0 }

    $obj = [ordered]@{}
    if ($st) { foreach ($p in $st.PSObject.Properties) { $obj[$p.Name] = $p.Value } }
    if (-not $obj.Contains('Version')) { $obj['Version'] = $script:Version }
    if (-not $obj.Contains('InstalledAt')) { $obj['InstalledAt'] = (Get-Date).ToString('s') }
    if (-not $obj.Contains('TaskName')) { $obj['TaskName'] = $script:TaskName }
    $obj['KeepExtra'] = @($list)
    $obj['KeepUpdatedAt'] = (Get-Date).ToString('s')

    if (-not (Test-Path -LiteralPath $script:InstallDir)) {
        New-Item -ItemType Directory -Path $script:InstallDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:InstallDir)) {
        Write-Ui ('   无法写入 {0}（需要管理员权限）。' -f $script:InstallDir) Yellow
        return 0
    }

    try {
        ([pscustomobject]$obj) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
        $script:KeepExtra = @($list)
    } catch {
        Write-Ui ('   保存保留名单失败：{0}' -f $_.Exception.Message) Yellow
        return 0
    }
    return $added
}

function Clear-StateKeep {
    # 清空“手动保留名单”，返回清掉的条数
    $st = Get-State
    $script:KeepExtra = @()
    if (-not $st -or -not ($st.PSObject.Properties.Name -contains 'KeepExtra')) { return 0 }

    $n = @($st.KeepExtra | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count

    $obj = [ordered]@{}
    foreach ($p in $st.PSObject.Properties) { $obj[$p.Name] = $p.Value }
    $obj['KeepExtra'] = @()
    $obj['KeepUpdatedAt'] = (Get-Date).ToString('s')

    try {
        ([pscustomobject]$obj) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
    } catch { }

    return $n
}

function Invoke-Pick {
    $rows = @(Get-AllEntries)
    if ($rows.Count -eq 0) {
        Write-Ui '没有找到任何命名空间项。' Green
        return 0
    }

    $res = Select-EntriesInteractive -Entries $rows -AutoSelect $SelectIds
    $targets = @($res.Selected)
    if ($targets.Count -eq 0) {
        if (-not [string]::IsNullOrWhiteSpace($SelectIds)) {
            Write-Ui '没有选中任何项：请检查 -SelectIds 里的序号是否在列表范围内（从 1 开始）。' Yellow
        }
        return 0
    }

    if ($DryRun) {
        Write-Ui '（DryRun：仅演示，未修改注册表）' Yellow
        return 0
    }

    if (-not $Scheduled) { Confirm-Admin }

    $out = Remove-SelectedEntries -Targets $targets
    Write-Log -Path $script:HistoryLog -Message ('手动挑选清理：' + $out.Summary)

    # 没被选中的项可以存进保留名单，免得守护任务以后又把它们删掉
    if ($out.Removed -gt 0 -and -not $Scheduled -and [string]::IsNullOrWhiteSpace($SelectIds)) {
        $picked = @($targets | ForEach-Object { $_.Name })
        $others = @($res.Candidates | Where-Object { $picked -notcontains $_.Name })

        if ($others.Count -gt 0) {
            Write-Ui ''
            $ans = [string](Read-Host ('把没选中的 {0} 项加入保留名单（以后自动清理不再动它们）？(y/N)' -f $others.Count))
            if ($ans -and ($ans.Trim().ToLower() -in @('y', 'yes', '是'))) {
                $added = Add-StateKeep -Items @($others | ForEach-Object { $_.Name })
                if ($added -gt 0) {
                    Write-Ui ('   已加入保留名单 {0} 项（保存在 state.json，守护任务同样遵守）。' -f $added) Green
                    Write-Ui '   想解除请运行：-Action Keep -ClearKeep' DarkGray
                } else {
                    Write-Ui '   这些项已经在保留名单里了。' DarkGray
                }
            }
        }
    }

    return $out.Removed
}

function Invoke-Keep {
    $cli = @($Keep | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $st = Get-State
    $saved = @()
    if ($st -and ($st.PSObject.Properties.Name -contains 'KeepExtra')) {
        $saved = @($st.KeepExtra | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    Write-Ui ''
    Write-Ui ('命令行 -Keep 指定的保留项：{0} 个' -f $cli.Count)
    foreach ($k in $cli) { Write-Ui ('   • ' + $k) DarkGray }
    Write-Ui ('手动挑选时保存的保留项：{0} 个' -f $saved.Count)
    foreach ($k in $saved) { Write-Ui ('   • ' + $k) DarkGray }
    Write-Ui ('   状态文件：' + $script:StateFile) DarkGray
    Write-Ui ''

    if ($cli.Count -eq 0 -and $saved.Count -eq 0) {
        Write-Ui '当前没有保留项，自动清理不会手下留情。' DarkGray
        Write-Ui '想保留某些图标：用 -Pick 手动挑选，或用 -Keep 指定关键字。' DarkGray
        return
    }

    $doClear = [bool]$ClearKeep
    if (-not $doClear -and $saved.Count -gt 0 -and $Host.Name -eq 'ConsoleHost' -and -not $script:QuietMode) {
        $ans = [string](Read-Host '清空这些“手动保存的保留项”？（y/N）')
        $doClear = ($ans -and ($ans.Trim().ToLower() -in @('y', 'yes', '是')))
    }
    if (-not $doClear) {
        Write-Ui '（未做改动。想清空请加 -ClearKeep）' DarkGray
        return
    }

    $n = Clear-StateKeep
    Write-Ui ('已清空手动保存的保留项：{0} 项。' -f $n) Green
    Write-Log -Path $script:HistoryLog -Message ('清空保留名单：{0} 项' -f $n)
}

function Invoke-Protect {
    if ($DryRun) {
        Write-Ui '（DryRun）将要执行：清理现有图标 → 加固用户命名空间键 → 注册守护任务' Yellow
        Invoke-Clean | Out-Null
        Write-Ui ''
        Write-Ui '将要加固的注册表键（拒绝当前用户创建子键）：' Cyan
        if ($NoGuardAcl) {
            Write-Ui '   （已按 -NoGuardAcl 跳过）' DarkGray
        } else {
            foreach ($t in Get-UserNamespaceTargets) {
                Write-Ui ('   {0}' -f $t.RegPath) DarkGray
            }
        }
        Write-Ui ''
        Write-Ui '将要注册的守护任务（每 N 分钟自动清理一次）：' Cyan
        Write-Ui ('   schtasks /Create /TN {0} /TR "{1}" /SC MINUTE /MO {2} /RU SYSTEM /RL HIGHEST /F' -f $script:TaskName, (Get-GuardCommandPath), $script:IntervalMinutes) DarkGray
        Write-Ui ('   启动脚本 {0} 的内容：' -f (Get-GuardCommandPath)) DarkGray
        Write-Ui ('     "{0}" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Action Clean -Quiet -Scheduled' -f (Get-PowerShellExe), $script:InstalledScript) DarkGray
        Write-Ui '   （DryRun：仅演示，未做任何改动）' Yellow
        return
    }

    Confirm-Admin
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    Write-Ui '1/3 清理现有网盘图标……' Cyan
    $removed = Invoke-Clean

    Write-Ui '2/3 加固当前用户的命名空间键……' Cyan
    $aclRecords = @()
    if ($NoGuardAcl) {
        Write-Ui '   已按 -NoGuardAcl 跳过权限加固。' DarkGray
    } else {
        $sid = Get-CurrentSid
        foreach ($t in Get-UserNamespaceTargets) {
            if (Add-CreateSubKeyDeny -Target $t -Sid $sid) {
                # 复核一遍：写完再读回来确认，避免“提示成功、其实没生效”
                if (Test-CreateSubKeyDeny -Target $t -Sid $sid) {
                    $aclRecords += $t.RegPath
                    Write-Ui ('   已加固：{0}' -f $t.RegPath) DarkGray
                } else {
                    Write-Ui ('   加固似乎没生效（写入后复核不到）：{0}' -f $t.RegPath) Yellow
                }
            } else {
                Write-Ui ('   未能加固：{0}' -f $t.RegPath) Yellow
            }
        }
    }

    Write-Ui '3/3 注册守护任务……' Cyan
    try {
        Copy-Item -LiteralPath $script:ScriptPath -Destination $script:InstalledScript -Force -ErrorAction Stop
    } catch {
        Write-Ui ('   复制脚本失败：{0}' -f $_.Exception.Message) Yellow
        Write-Ui ('   守护任务改为直接使用原脚本路径：{0}' -f $script:ScriptPath) Yellow
        Write-Ui '   注意：请不要移动或删除这个文件，否则守护任务会失效。' Yellow
        $script:InstalledScript = $script:ScriptPath
    }
    $taskOk = $true
    try {
        Install-GuardTask
    } catch {
        $taskOk = $false
        Write-Ui ('   守护任务注册失败：{0}' -f $_.Exception.Message) Yellow
        Write-Ui '   “禁止新增图标”的权限加固已经生效，只有“定时清理”没装上。' Yellow
        Write-Ui '   可以稍后重跑一次 -Action Protect 补上，或忽略这一项。' Yellow
    }
    if ($taskOk) {
        $info = Get-GuardTaskInfo
        if (-not $info.Exists) {
            Write-Ui '   守护任务似乎没有注册成功，请检查“任务计划程序”服务是否正常。' Yellow
            $taskOk = $false
        }
    }
    Save-State -AclRecords $aclRecords

    Write-Ui ''
    Write-Ui '防护已开启：' Green
    if ($taskOk) {
        Write-Ui ('   • 守护任务 {0} 每 {1} 分钟自动清理一次（开机后也按同样间隔继续）。' -f $script:TaskName, $IntervalMinutes)
    } else {
        Write-Ui '   • 守护任务未安装：自动清理不会定时跑，图标新增仍被权限规则拦住。' Yellow
    }
    Write-Ui '   • 当前用户再往命名空间键里创建子键会被拒绝。'
    Write-Ui ('   • 已安装副本：{0}' -f $script:InstalledScript)
    Write-Ui '   • 取消请运行：-Action Unprotect' DarkGray

    Write-Log -Path $script:HistoryLog -Message ('开启防护：清理 {0} 个，加固 {1} 处，守护任务 {2}，间隔 {3} 分钟' -f $removed, $aclRecords.Count, $(if ($taskOk) { '已注册' } else { '未注册' }), $IntervalMinutes)
}

function Invoke-Unprotect {
    if ($DryRun) {
        Write-Ui '（DryRun）将要执行：删除守护任务 → 撤销权限加固' Yellow
        $sid = Get-CurrentSid
        Write-Ui '将要撤销的拒绝规则所在键：' Cyan
        if (@(Get-UserNamespaceTargets).Count -eq 0) {
            Write-Ui '   （找不到当前用户的命名空间键）' DarkGray
        } else {
            foreach ($t in Get-UserNamespaceTargets) {
                $state = '当前有拒绝规则'
                if (-not (Test-CreateSubKeyDeny -Target $t -Sid $sid)) { $state = '当前没有拒绝规则' }
                Write-Ui ('   {0}（{1}）' -f $t.RegPath, $state) DarkGray
            }
        }
        Write-Ui '   （DryRun：仅演示，未做任何改动）' Yellow
        return
    }

    Confirm-Admin
    Write-Ui '1/2 删除守护任务……' Cyan
    $existed = Uninstall-GuardTask
    if ($existed) {
        Write-Ui ('   已删除计划任务 {0}。' -f $script:TaskName) DarkGray
    } else {
        Write-Ui ('   没有找到计划任务 {0}（本来就没装）。' -f $script:TaskName) DarkGray
    }

    Write-Ui '2/2 撤销权限加固……' Cyan
    $sid = Get-CurrentSid

    # 注意：不能依赖 state.json —— 旧版本可能在“写状态”之前就失败了，
    # 结果就是“权限加了、状态没存”，这种情况下靠状态文件去撤销会一条都没撤。
    $targets = @(Get-UserNamespaceTargets)
    foreach ($t in $targets) {
        $n = Remove-CreateSubKeyDeny -Target $t -Sid $sid
        switch ($n) {
            -1 { Write-Ui ('   未能撤销（权限不足）：{0}' -f $t.RegPath) Yellow }
            0  { Write-Ui ('   无需撤销（本来就没有拒绝规则）：{0}' -f $t.RegPath) DarkGray }
            default { Write-Ui ('   已撤销 {0} 条拒绝规则：{1}' -f $n, $t.RegPath) DarkGray }
        }
    }

    # 复核：还留着就是没撤干净，把 DACL 打出来，别让用户以为已经好了
    $stillBlocked = @()
    foreach ($t in $targets) {
        if (Test-CreateSubKeyDeny -Target $t -Sid $sid) { $stillBlocked += $t }
    }
    if ($stillBlocked.Count -gt 0) {
        Write-Ui ''
        Write-Ui '注意：下面这些键仍然“拒绝当前用户创建子键”，加固没有完全撤销。' Yellow
        Write-Ui '  请以管理员身份重新运行一次；如果还是不行，把下面这段发给我看：' Yellow
        foreach ($t in $stillBlocked) {
            Write-Ui ('  · {0}' -f $t.RegPath) Yellow
            foreach ($line in ((Get-TargetAclDump -Target $t) -split "`r`n")) {
                Write-Ui ('      ' + $line) DarkGray
            }
        }
        Write-Log -Path $script:HistoryLog -Message ('取消防护：有 {0} 个键的拒绝规则未能撤销' -f $stillBlocked.Count)
    } else {
        Write-Ui '   复核通过：当前用户的命名空间键已恢复可创建子键。' DarkGray
    }

    if (Test-Path -LiteralPath $script:StateFile) {
        try { Remove-Item -LiteralPath $script:StateFile -Force -ErrorAction SilentlyContinue } catch { }
    }

    # 顺手清掉装到 ProgramData 的副本（守护任务已经删了，留着没用）
    if ($script:InstalledScript -and ($script:InstalledScript -ne $script:ScriptPath) -and (Test-Path -LiteralPath $script:InstalledScript)) {
        try {
            Remove-Item -LiteralPath $script:InstalledScript -Force -ErrorAction Stop
            Write-Ui ('   已删除安装副本：{0}' -f $script:InstalledScript) DarkGray
        } catch { }
    }

    Write-Ui ''
    Write-Ui '防护已取消。已经删除的图标不会自动回来；如需恢复请用 -Action Restore。' Green
    Write-Log -Path $script:HistoryLog -Message '已取消防护'
}

function Invoke-Restore {
    $dir = $RestoreFrom
    if (-not $dir) {
        if (-not (Test-Path -LiteralPath $BackupRoot)) {
            Write-Ui '还没有任何备份，无需恢复。' Yellow
            return
        }
        $latest = Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if (-not $latest) {
            Write-Ui ('备份目录为空：' + $BackupRoot) Yellow
            return
        }
        $dir = $latest.FullName
    }
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-Ui ('备份目录不存在：' + $dir) Yellow
        return
    }

    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.reg' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if (-not $files) {
        Write-Ui ('该备份目录里没有 .reg 文件：' + $dir) Yellow
        return
    }

    Write-Ui ('将从备份恢复：{0}' -f $dir) Cyan
    foreach ($f in $files) { Write-Ui ('   ' + $f.Name) DarkGray }

    $sid = Get-CurrentSid
    $blocked = @()
    foreach ($t in Get-UserNamespaceTargets) {
        if (Test-CreateSubKeyDeny -Target $t -Sid $sid) { $blocked += $t.RegPath }
    }
    if ($blocked.Count -gt 0) {
        Write-Ui ''
        Write-Ui '注意：当前用户命名空间仍处于“禁止创建子键”状态，写在这些位置的项目会恢复失败。' Yellow
        Write-Ui '      如需完整恢复，请先执行 -Action Unprotect 取消防护，然后再恢复。' Yellow
    }

    if ($DryRun) {
        Write-Ui '（DryRun：未导入）' Yellow
        return
    }

    Confirm-Admin
    $ok = 0
    $bad = 0
    foreach ($f in $files) {
        try {
            $out = & reg.exe import $f.FullName 2>&1
            if ($LASTEXITCODE -eq 0) { $ok++ }
            else {
                $bad++
                Write-Ui ('   导入失败：{0}（{1}）' -f $f.Name, ($out -join ' ')) Yellow
            }
        } catch {
            $bad++
            Write-Ui ('   导入失败：{0}（{1}）' -f $f.Name, $_.Exception.Message) Yellow
        }
    }

    Refresh-Explorer
    Write-Ui ('恢复完成：成功 {0} 个，失败 {1} 个。' -f $ok, $bad) Green
    Write-Log -Path $script:HistoryLog -Message ('从备份恢复：{0}（成功 {1}，失败 {2}）' -f $dir, $ok, $bad)
}

function Invoke-Status {
    $state = Get-State
    $taskInfo = Get-GuardTaskInfo
    $sid = Get-CurrentSid

    Write-Ui ''
    Write-Ui '【守护任务】' Cyan
    if ($taskInfo.Exists) {
        Write-Ui ('   名称：{0}' -f $script:TaskName)
        Write-Ui ('   状态：{0}' -f $taskInfo.State)
        if ($taskInfo.LastRun) { Write-Ui ('   上次运行：{0}' -f $taskInfo.LastRun) }
        if ($taskInfo.NextRun) { Write-Ui ('   下次运行：{0}' -f $taskInfo.NextRun) }
        if ($taskInfo.Interval) { Write-Ui ('   任务内置间隔：{0}' -f $taskInfo.Interval) }
    } else {
        Write-Ui '   未安装（运行 -Action Protect 开启防护）' Yellow
    }
    if ($state -and $state.IntervalMinutes) {
        Write-Ui ('   清理间隔：每 {0} 分钟' -f $state.IntervalMinutes)
    }

    Write-Ui ''
    Write-Ui '【权限加固】' Cyan
    $guardedCount = 0
    $nsTargets = @(Get-UserNamespaceTargets)
    foreach ($t in $nsTargets) {
        $guarded = Test-CreateSubKeyDeny -Target $t -Sid $sid
        if ($guarded) { $guardedCount++ }
        Write-Ui ('   {0}：{1}' -f $t.RegPath, $(if ($guarded) { '已禁止当前用户创建子键' } else { '未加固' }))
    }
    if ($nsTargets.Count -eq 0) { Write-Ui '   （找不到可加固的注册表键）' DarkGray }

    Write-Ui ''
    Write-Ui '【当前图标】' Cyan
    $rows = @(Get-AllEntries)
    $delete = @($rows | Where-Object { $_.Verdict -eq 'Delete' })
    $unknown = @($rows | Where-Object { $_.Verdict -eq 'Unknown' })
    Write-Ui ('   网盘图标 {0} 个，来源不明 {1} 个，系统/保留 {2} 个' -f $delete.Count, $unknown.Count, ($rows.Count - $delete.Count - $unknown.Count))
    if ($delete.Count -gt 0) { Write-EntryRows $delete }

    Write-Ui ''
    Write-Ui '【备份】' Cyan
    if (Test-Path -LiteralPath $BackupRoot) {
        $latest = Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($latest) { Write-Ui ('   最近备份：{0}' -f $latest.FullName) } else { Write-Ui '   （空）' DarkGray }
    } else {
        Write-Ui '   （无备份）' DarkGray
    }
    Write-Ui ''
}

# -------------------------------------------------------------------- 交互菜单 --
function Show-Menu {
    while ($true) {
        Write-Banner
        Write-Ui ' 1) 扫描（只看，不改动）'
        Write-Ui ' 2) 手动挑选要清理 / 保留的图标'
        Write-Ui ' 3) 立即清理现有网盘图标'
        Write-Ui ' 4) 开启防护（清理 + 禁止新增 + 定时守护）'
        Write-Ui ' 5) 查看状态'
        Write-Ui ' 6) 取消防护'
        Write-Ui ' 7) 从备份恢复'
        Write-Ui ' 8) 查看 / 清空保留名单'
        Write-Ui ' 0) 退出'
        Write-Ui ''
        $c = Read-Host '请输入序号'
        if ($null -eq $c) { return 'Exit' }   # 输入流结束（例如管道喂入或窗口被关）
        switch ($c.Trim()) {
            '1' { return 'Scan' }
            '2' { return 'Pick' }
            '3' { return 'Clean' }
            '4' { return 'Protect' }
            '5' { return 'Status' }
            '6' { return 'Unprotect' }
            '7' { return 'Restore' }
            '8' { return 'Keep' }
            '0' { return 'Exit' }
            default { Write-Ui '无效输入，请重新选择。' Yellow; Write-Ui '' }
        }
    }
}

function Resolve-Action {
    if ($Scheduled) { return 'Clean' }
    if ($Pick -and -not $Action) { return 'Pick' }
    if ((-not [string]::IsNullOrWhiteSpace($SelectIds)) -and -not $Action) { return 'Pick' }
    if ($ClearKeep -and -not $Action) { return 'Keep' }
    if ($Action) {
        switch ($Action.ToLower()) {
            'scan' { return 'Scan' }
            'clean' { return 'Clean' }
            'pick' { return 'Pick' }
            'keep' { return 'Keep' }
            'protect' { return 'Protect' }
            'unprotect' { return 'Unprotect' }
            'restore' { return 'Restore' }
            'status' { return 'Status' }
            default { throw ('未知操作：' + $Action + '（可用：Scan / Clean / Pick / Keep / Protect / Unprotect / Restore / Status）') }
        }
    }
    if ($Host.Name -eq 'ConsoleHost' -and -not $script:QuietMode) { return (Show-Menu) }
    return 'Scan'
}

# ---------------------------------------------------------------------- 主流程 --
function Invoke-Main {
    $script:QuietMode = [bool]$Quiet -or [bool]$Scheduled
    $script:UseAllUsers = [bool]$Scheduled -or (Test-IsSystem)

    # 读回“手动保留名单”，让自动清理 / 守护任务也尊重用户手动保留的选择
    $st = Get-State
    if ($st -and ($st.PSObject.Properties.Name -contains 'KeepExtra')) {
        $script:KeepExtra = @($st.KeepExtra | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }

    if ($script:IntervalMinutes -lt 1) { $script:IntervalMinutes = 1 }

    # 只要给了任何命令行参数，就按“一次性执行”处理，不再进菜单循环
    $scripted = [bool]$Action -or [bool]$Pick -or [bool]$ClearKeep -or (-not [string]::IsNullOrWhiteSpace($SelectIds)) -or [bool]$DryRun -or [bool]$IncludeDesktop -or [bool]$AllUnknown
    $interactive = ($Host.Name -eq 'ConsoleHost') -and (-not $scripted) -and (-not $script:QuietMode) -and (-not $Scheduled) -and (-not $Elevated)

    while ($true) {
        $chosen = Resolve-Action
        if ($chosen -eq 'Exit') { return }

        $needsAdmin = @('Clean', 'Pick', 'Protect', 'Unprotect') -contains $chosen
        if ($chosen -eq 'Restore') {
            $hasBackup = [bool]$RestoreFrom
            if (-not $hasBackup -and (Test-Path -LiteralPath $BackupRoot)) {
                $hasBackup = (@(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue).Count -gt 0)
            }
            if ($hasBackup) { $needsAdmin = $true }
        }
        if ($needsAdmin -and -not $DryRun -and -not (Test-IsAdmin) -and -not $Scheduled) {
            Invoke-SelfElevate -ChosenAction $chosen
            return
        }

        if (-not $Scheduled) { Write-Banner }

        switch ($chosen) {
            'Scan' { Invoke-Scan }
            'Pick' { Invoke-Pick | Out-Null }
            'Clean' { Invoke-Clean | Out-Null }
            'Keep' { Invoke-Keep }
            'Protect' { Invoke-Protect }
            'Unprotect' { Invoke-Unprotect }
            'Restore' { Invoke-Restore }
            'Status' { Invoke-Status }
        }

        if (-not $interactive) { break }
        Write-Ui ''
        [void](Read-Host '按回车键返回菜单（或直接关窗口退出）')
    }

    if ($Elevated -and -not $script:QuietMode -and $Host.Name -eq 'ConsoleHost') {
        Write-Ui ''
        [void](Read-Host '按回车键关闭窗口')
    }
}

try {
    Invoke-Main
} catch {
    $msg = $_.Exception.Message
    $pos = ($_.InvocationInfo.PositionMessage -replace '[\r\n]+', ' ')
    Write-Ui ''
    Write-Ui ('出错：' + $msg) Red
    Write-Ui '   如反复出现，请右键“以管理员身份运行”后再试。' DarkGray
    if ($script:QuietMode) { Write-Log -Path $script:GuardLog -Message ('出错：{0}（{1}）' -f $msg, $pos) }
    else { Write-Log -Path $script:HistoryLog -Message ('出错：{0}（{1}）' -f $msg, $pos) }
    if (-not $script:QuietMode) { [void](Read-Host '按回车键退出') }
    exit 1
}
