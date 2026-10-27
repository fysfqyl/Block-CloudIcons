# 判定逻辑自测：不写注册表，用构造的条目验证 Resolve-Verdict
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Verdicts.ps1
param([string]$FuncsPath = '')

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$main = Join-Path (Split-Path -Parent $here) 'Block-CloudIcons.ps1'
if (-not (Test-Path -LiteralPath $main)) { throw ('找不到主脚本：' + $main) }

# 生成一份“去掉主流程”的函数副本，便于 dot-source 后单独测试各函数
if (-not $FuncsPath) {
    $txt = [System.IO.File]::ReadAllText($main, [System.Text.Encoding]::UTF8)
    $marker = "try {`r`n    Invoke-Main"
    $idx = $txt.IndexOf($marker)
    if ($idx -lt 0) { $idx = $txt.IndexOf("try {`n    Invoke-Main") }
    if ($idx -lt 0) { throw '无法定位主流程入口（try { Invoke-Main }）。' }
    $FuncsPath = Join-Path $env:TEMP 'nci-funcs.ps1'
    [System.IO.File]::WriteAllText($FuncsPath, $txt.Substring(0, $idx), (New-Object System.Text.UTF8Encoding($true)))
}
if (-not (Test-Path -LiteralPath $FuncsPath)) { throw ('找不到函数副本：' + $FuncsPath) }

$global:Keep = @()
$global:AllUnknown = $false
$global:IncludeDesktop = $false
$global:Quiet = $true
$global:DryRun = $true
$global:BackupRoot = Join-Path $env:TEMP 'nci-test-backup'
$global:InstallDir = Join-Path $env:TEMP 'nci-test-install'
$global:Scheduled = $false
$global:Elevated = $false
$global:Action = $null
$global:RestoreFrom = ''
$global:IntervalMinutes = 5
$global:NoGuardAcl = $false

. $FuncsPath

function New-FakeEntry {
    param(
        [string]$Name,
        [string]$Display = '',
        [string]$Dll = '',
        [string]$Default = '',
        [string]$DefaultIcon = '',
        [bool]$InHKCU = $false,
        [bool]$InHKLM = $false,
        [bool]$IsThisPC = $false
    )

    $sd = Test-IsSystemDll -Dll $Dll

    $icon = $DefaultIcon
    if ($icon) { $icon = [Environment]::ExpandEnvironmentVariables($icon) }
    $iconOutside = $false
    if ($icon -and ($icon -match '^[A-Za-z]:\\' -or $icon -match '^\\\\')) {
        $iconOutside = -not (Test-IsSystemDll -Dll $icon)
    }

    # 与主脚本 Get-Entries 里的“强证据”规则保持一致
    $strong = @()
    if ($iconOutside) { $strong += '图标不在系统目录' }
    if ($IsThisPC -and $Default -and $Default -notlike 'CLSID_*') { $strong += '命名项有自定义名称' }
    if ($InHKCU -and -not $InHKLM) { $strong += '只注册在 HKCU' }
    if ($Dll -and -not $sd) { $strong += 'DLL 不在系统目录' }

    [pscustomobject]@{
        Name        = $Name
        Default     = $Default
        Display     = $Display
        Dll         = $Dll
        Product     = ''
        Localized   = ''
        DefaultIcon = $DefaultIcon
        InHKCU      = $InHKCU
        HasShell    = $false
        SystemDll   = $sd
        ThirdParty  = @($strong)
        Strong      = @($strong)
        IsThisPC    = $IsThisPC
        Haystack    = (@($Name, $Default, $Display, $DefaultIcon, $Dll) -join ' ')
        Verdict     = ''
        Reason      = ''
        Target      = [pscustomobject]@{ Label = '测试' }
    }
}

$cases = @(
    @{ E = (New-FakeEntry '{11111111-1111-1111-1111-111111111111}' '百度网盘' 'C:\Program Files\Baidu\BaiduNetdisk\ShellExt.dll'); Want = 'Delete'; Why = '显示名命中网盘' }
    @{ E = (New-FakeEntry '{22222222-2222-2222-2222-222222222222}' 'OneDrive' 'C:\Users\me\AppData\Local\Microsoft\OneDrive\FileSyncShell64.dll'); Want = 'Delete'; Why = 'OneDrive' }
    @{ E = (New-FakeEntry '{33333333-3333-3333-3333-333333333333}' 'x' 'C:\Windows\system32\shell32.dll'); Want = 'Keep'; Why = '系统 DLL' }
    @{ E = (New-FakeEntry '{b4bfcc3a-db2c-424c-b029-7fe99a87c641}' '桌面' 'C:\Windows\system32\windows.storage.dll'); Want = 'Keep'; Why = '内置 CLSID' }
    @{ E = (New-FakeEntry '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}' '桌面' 'C:\Windows\system32\windows.storage.dll'); Want = 'Keep'; Why = '内置 CLSID 大写形式' }
    @{ E = (New-FakeEntry '{44444444-4444-4444-4444-444444444444}' 'AbcTool' 'C:\Program Files\Abc\abc.dll'); Want = 'Unknown'; Why = '未知第三方' }
    @{ E = (New-FakeEntry '{55555555-5555-5555-5555-555555555555}' '腾讯微云' ''); Want = 'Delete'; Why = '微云（无 DLL）' }
    @{ E = (New-FakeEntry '{66666666-6666-6666-6666-666666666666}' 'QuarkCloud' 'D:\quark\ext.dll'); Want = 'Delete'; Why = '夸克英文名' }

    # 真实回归：百度网盘用系统 DLL（shdocvw.dll）当宿主，靠 DefaultIcon 和命名空间默认值识别
    @{ E = (New-FakeEntry '{679F137C-3162-45da-BE3C-2F9C3D093F64}' 'Microsoft® Windows® Operating System' 'C:\WINDOWS\system32\shdocvw.dll' '百度网盘' 'D:\BaiduNetdisk\netdisk_logo.ico' $true $false $true); Want = 'Delete'; Why = '百度网盘（系统 DLL 宿主）' }
    @{ E = (New-FakeEntry '{aaaaaaaa-1111-2222-3333-444444444444}' 'Microsoft® Windows® Operating System' 'C:\Windows\system32\shell32.dll' '我的加密盘' 'C:\Windows\system32\shell32.dll,-1' $false $true $true); Want = 'Delete'; Why = '此电脑项：非系统命名项（系统 DLL + 系统图标）' }
    @{ E = (New-FakeEntry '{450D8FBA-AD25-11D0-98A8-0800361B1103}' 'Microsoft® Windows® Operating System' 'C:\WINDOWS\system32\shell32.dll' 'Documents' 'C:\WINDOWS\system32\shell32.dll,-235' $false $true $false); Want = 'Keep'; Why = '桌面系统文件夹（不应误删）' }
)

$fail = 0
foreach ($c in $cases) {
    $v = Resolve-Verdict -Entry $c.E
    $ok = ($v.Verdict -eq $c.Want)
    if (-not $ok) { $fail++ }
    '{0}  期望={1,-7} 实际={2,-7} 依据={3,-28} 用例：{4}' -f $(if ($ok) { '[通过]' } else { '[失败]' }), $c.Want, $v.Verdict, $v.Reason, $c.Why
}

# -AllUnknown 时应把未知项判为删除
$global:AllUnknown = $true
$v2 = Resolve-Verdict -Entry (New-FakeEntry '{77777777-7777-7777-7777-777777777777}' 'AbcTool' 'C:\Program Files\Abc\abc.dll')
$ok2 = ($v2.Verdict -eq 'Delete')
if (-not $ok2) { $fail++ }
'{0}  期望=Delete  实际={1,-7} 依据={2,-28} 用例：-AllUnknown 覆盖未知项' -f $(if ($ok2) { '[通过]' } else { '[失败]' }), $v2.Verdict, $v2.Reason

# -Keep 白名单优先
$global:AllUnknown = $false
$global:Keep = @('AbcTool')
$v3 = Resolve-Verdict -Entry (New-FakeEntry '{88888888-8888-8888-8888-888888888888}' 'AbcTool' 'C:\Program Files\Abc\abc.dll')
$ok3 = ($v3.Verdict -eq 'Keep')
if (-not $ok3) { $fail++ }
'{0}  期望=Keep    实际={1,-7} 依据={2,-28} 用例：-Keep 白名单' -f $(if ($ok3) { '[通过]' } else { '[失败]' }), $v3.Verdict, $v3.Reason

# 表格宽度渲染（中文对齐）
$global:Keep = @()
$rows = @(
    (Format-EntryRow -Entry (New-FakeEntry '{99999999-9999-9999-9999-999999999999}' '百度网盘（超长名称测试，用来检查表格截断是否正常显示省略号结尾）' 'C:\Program Files\Baidu\BaiduNetdisk\ShellExt.dll'))
)
$table = ($rows | Out-String -Width 300)
Write-Host ''
Write-Host '—— 表格渲染样例 ——'
Write-Table $rows

Write-Host ''
if ($fail -eq 0) { Write-Host ('全部用例通过。') -ForegroundColor Green; exit 0 }
else { Write-Host ('有 {0} 个用例失败。' -f $fail) -ForegroundColor Red; exit 1 }
