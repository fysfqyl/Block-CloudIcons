# 备份 / 状态文件 集成测试（不写注册表，只跑文件相关流程）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Integration.ps1
param([string]$FuncsPath = '')

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$main = Join-Path (Split-Path -Parent $here) 'Block-CloudIcons.ps1'
if (-not (Test-Path -LiteralPath $main)) { throw ('找不到主脚本：' + $main) }

if (-not $FuncsPath) {
    $txt = [System.IO.File]::ReadAllText($main, [System.Text.Encoding]::UTF8)
    $marker = "try {`r`n    Invoke-Main"
    $idx = $txt.IndexOf($marker)
    if ($idx -lt 0) { $idx = $txt.IndexOf("try {`n    Invoke-Main") }
    if ($idx -lt 0) { throw '无法定位主流程入口。' }
    $FuncsPath = Join-Path $env:TEMP 'nci-funcs.ps1'
    [System.IO.File]::WriteAllText($FuncsPath, $txt.Substring(0, $idx), (New-Object System.Text.UTF8Encoding($true)))
}

$sandbox = Join-Path $env:TEMP ('nci-int-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

$global:Quiet = $false
$global:DryRun = $false
$global:Keep = @()
$global:AllUnknown = $false
$global:IncludeDesktop = $false
$global:Scheduled = $false
$global:Elevated = $false
$global:Action = $null
$global:RestoreFrom = ''
$global:IntervalMinutes = 5
$global:NoGuardAcl = $false

. $FuncsPath

# 必须在 dot-source 之后再覆盖路径：主脚本函数体自己会给 $script:BackupRoot /
# $script:InstallDir / $script:StateFile 赋值，早于 dot-source 的设置会被冲掉。
$script:BackupRoot = Join-Path $sandbox 'Backup'
$script:InstallDir = Join-Path $sandbox 'Install'
$script:StateFile = Join-Path $script:InstallDir 'state.json'
$script:HistoryLog = Join-Path $script:InstallDir 'history.log'
$script:GuardLog = Join-Path $script:InstallDir 'guard.log'

$fail = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ('[通过] ' + $Name) -ForegroundColor Green }
    else { Write-Host ('[失败] ' + $Name + '  ' + $Detail) -ForegroundColor Red; $script:fail++ }
}

Write-Host '—— 备份流程 ——' -ForegroundColor Cyan
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
$dir = New-BackupDirectory
Check '创建备份目录' (Test-Path -LiteralPath $dir) $dir
Check '备份目录带时间戳' ((Split-Path -Leaf $dir) -match '^\d{8}-\d{6}') (Split-Path -Leaf $dir)

$regPath = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace'
$file = Export-RegKey -RegPath $regPath -Directory $dir
Check '导出 .reg' ([bool]$file -and (Test-Path -LiteralPath $file)) ([string]$file)
if ($file) {
    $head = (Get-Content -LiteralPath $file -TotalCount 2 -Encoding Unicode) -join '|'
    Check '备份文件是标准 .reg' ($head -like '*Windows Registry Editor Version 5.00*') $head
    Check '备份文件非空' ((Get-Item -LiteralPath $file).Length -gt 200) ((Get-Item -LiteralPath $file).Length.ToString())
}

$manifest = @([pscustomobject]@{ '位置' = '测试'; 'CLSID' = '{0000}'; '结果' = '已删除' })
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $dir 'manifest.json') -Encoding UTF8
$back = Get-Content -LiteralPath (Join-Path $dir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Check 'manifest 可回读' ($back[0].'结果' -eq '已删除') ([string]$back[0].'结果')

Write-Host ''
Write-Host '—— 旧备份清理（保留 3 份）——' -ForegroundColor Cyan
1..5 | ForEach-Object {
    $d = Join-Path $BackupRoot ('2020010{0}-000000' -f $_)
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}
Remove-OldBackups -KeepCount 3
$left = @(Get-ChildItem -LiteralPath $BackupRoot -Directory)
Check '只保留 3 份备份' ($left.Count -eq 3) ('实际 ' + $left.Count)

Write-Host ''
Write-Host '—— 状态文件 ——' -ForegroundColor Cyan
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Save-State -AclRecords @($regPath)
Check 'state.json 已写出' (Test-Path -LiteralPath $script:StateFile) $script:StateFile
$st = Get-State
Check '状态可回读' ($null -ne $st -and $st.TaskName -eq $script:TaskName) ([string]$st.TaskName)
Check '状态记录加固项' (@($st.GuardAcl).Count -eq 1) ([string]@($st.GuardAcl).Count)

Write-Host ''
Write-Host '—— 序号解析（-SelectIds / 手动输入）——' -ForegroundColor Cyan
$r = ConvertTo-SelectionIndexes -Text '1,3-5' -Max 10
Check '解析 1,3-5' ((@($r) -join ',') -eq '1,3,4,5') (@($r) -join ',')
$r = ConvertTo-SelectionIndexes -Text '5-3' -Max 10
Check '倒序区间按升序展开' ((@($r) -join ',') -eq '3,4,5') (@($r) -join ',')
$r = ConvertTo-SelectionIndexes -Text '2 2、1;4' -Max 10
Check '多种分隔符 + 自动去重' ((@($r) -join ',') -eq '1,2,4') (@($r) -join ',')
Check '越界返回空' ($null -eq (ConvertTo-SelectionIndexes -Text '11' -Max 10)) '11'
Check '0 视为无效' ($null -eq (ConvertTo-SelectionIndexes -Text '0' -Max 10)) '0'
Check '乱输返回空' ($null -eq (ConvertTo-SelectionIndexes -Text 'abc' -Max 10)) 'abc'
Check '空输入返回空' ($null -eq (ConvertTo-SelectionIndexes -Text '   ' -Max 10)) 'blank'

Write-Host ''
Write-Host '—— 保留名单（state.json / KeepExtra）——' -ForegroundColor Cyan
$script:KeepExtra = @()
$n = Add-StateKeep -Items @('{AAAA}', '{BBBB}')
Check '加入保留名单 2 项' ($n -eq 2) ([string]$n)
$st = Get-State
Check 'KeepExtra 已写入 state.json' (@($st.KeepExtra).Count -eq 2) (@($st.KeepExtra) -join ',')
$n = Add-StateKeep -Items @('{AAAA}', '{CCCC}')
Check '重复项不重复添加' ($n -eq 1) ([string]$n)

$fake = [pscustomobject]@{
    Name = '{AAAA}'; Display = '某网盘'; Dll = 'C:\x\y.dll'; Product = 'x'; Haystack = '某网盘'
    ThirdParty = @(); Strong = @(); SystemDll = $false; IsThisPC = $true
}
Check '保留名单命中' ((Test-KeepHit -Entry $fake) -like '手动保留：*') (Test-KeepHit -Entry $fake)
$v = Resolve-Verdict -Entry $fake
Check '保留名单优先生效' ($v.Verdict -eq 'Keep') $v.Verdict

$n = Clear-StateKeep
Check '清空保留名单' ($n -eq 3) ([string]$n)
$st = Get-State
Check '清空后 KeepExtra 为空' (@($st.KeepExtra).Count -eq 0) ([string]@($st.KeepExtra).Count)

$script:KeepExtra = @('{DDDD}')
Save-State -AclRecords @()
$st = Get-State
Check 'Save-State 不会丢掉 KeepExtra' (@($st.KeepExtra).Count -eq 1 -and (@($st.KeepExtra)[0] -eq '{DDDD}')) (@($st.KeepExtra) -join ',')
$script:KeepExtra = @()

Write-Host ''
Write-Host '—— 拒绝创建子键的 ACE 识别与删除（纯内存，不写注册表）——' -ForegroundColor Cyan
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
function New-TestAcl {
    param([string]$Sddl)
    $s = New-Object System.Security.AccessControl.RegistrySecurity
    $s.SetSecurityDescriptorSddlForm($Sddl)
    return $s
}
function Get-ExplicitCount {
    param($Acl)
    return @($Acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])).Count
}

$acl = New-TestAcl ('D:AI(D;CI;LC;;;{0})(A;OICI;KA;;;{0})(A;OICI;KA;;;SY)' -f $sid)
Check '能识别本脚本加的拒绝规则' (@(Get-CreateSubKeyDenyRules -Acl $acl -Sid $sid).Count -eq 1) ([string]@(Get-CreateSubKeyDenyRules -Acl $acl -Sid $sid).Count)

$acl2 = New-TestAcl ('D:(D;;KA;;;{0})' -f $sid)
Check '组合权限里的 CreateSubKey 也认得（按位判断）' (@(Get-CreateSubKeyDenyRules -Acl $acl2 -Sid $sid).Count -eq 1) ([string]@(Get-CreateSubKeyDenyRules -Acl $acl2 -Sid $sid).Count)

$acl3 = New-TestAcl 'D:(D;CI;LC;;;S-1-5-21-1111-2222-3333-4444)'
Check '别的 SID 的拒绝规则不算' (@(Get-CreateSubKeyDenyRules -Acl $acl3 -Sid $sid).Count -eq 0) 'other-sid'

$acl4 = New-TestAcl ('D:(A;CI;LC;;;{0})' -f $sid)
Check '允许类 ACE 不算拒绝规则' (@(Get-CreateSubKeyDenyRules -Acl $acl4 -Sid $sid).Count -eq 0) 'allow'

# 关键回归：RemoveAccessRuleSpecific 返回 void，改成“数条数”后必须真的删掉
$before = Get-ExplicitCount -Acl $acl
foreach ($rule in @(Get-CreateSubKeyDenyRules -Acl $acl -Sid $sid)) { $acl.RemoveAccessRuleSpecific($rule) }
Check '原对象上删除后不再命中' (@(Get-CreateSubKeyDenyRules -Acl $acl -Sid $sid).Count -eq 0) 'after-inplace'
Check '只删掉那一条，其它显式规则还在' ((Get-ExplicitCount -Acl $acl) -eq ($before - 1)) ([string](Get-ExplicitCount -Acl $acl))

# 兜底路径：整份 DACL 重写
$acl5 = New-TestAcl ('D:AI(D;CI;LC;;;{0})(A;OICI;KA;;;{0})(A;OICI;KA;;;SY)' -f $sid)
$cleaned = New-AclWithoutCreateSubKeyDeny -Acl $acl5 -Sid $sid
Check '重写后的 ACL 不含拒绝规则' (@(Get-CreateSubKeyDenyRules -Acl $cleaned -Sid $sid).Count -eq 0) 'rebuild'
Check '重写后保留原显式规则' ((Get-ExplicitCount -Acl $cleaned) -eq 2) ([string](Get-ExplicitCount -Acl $cleaned))
Check '重写后继承关系仍开启' (-not $cleaned.AreAccessRulesProtected) 'inheritance'
Check '重写结果有内容（不是空 DACL）' ($cleaned.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access) -like 'D:*(A;*') 'sddl'

Write-Host ''
Write-Host '—— 备份目录不可用时宁可不动 ——' -ForegroundColor Cyan
$savedRoot = $script:BackupRoot
$blocker = Join-Path $sandbox 'notadir'
Set-Content -LiteralPath $blocker -Value 'x' -Encoding ASCII    # 用同名文件占住，目录就建不出来
$script:BackupRoot = $blocker
$script:QuietMode = $true
$probe = [pscustomobject]@{
    Name = '{ZZZZ}'; Display = '测试项'; Dll = 'C:\x\y.dll'; Reason = '测试'
    Target = [pscustomobject]@{
        Label = 'HKCU · 此电脑'
        RegPath = 'HKEY_CURRENT_USER\Software\_nci_none'
        SubPath = '\MyComputer\NameSpace'
    }
}
$out = Remove-SelectedEntries -Targets @($probe)
Check '备份失败时不删除' ($out.Removed -eq 0) ([string]$out.Removed)
Check '备份失败计入跳过' ($out.Skipped -eq 1) ([string]$out.Skipped)
Check '汇总说明未做改动' ($out.Summary -like '*未做任何改动*') $out.Summary
$script:BackupRoot = $savedRoot
$script:QuietMode = $false

Write-Host ''
Write-Host '—— 收尾 ——' -ForegroundColor Cyan
Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
Check '临时目录已清理' (-not (Test-Path -LiteralPath $sandbox)) $sandbox

Write-Host ''
if ($fail -eq 0) { Write-Host '全部用例通过。' -ForegroundColor Green; exit 0 }
Write-Host ('有 {0} 个用例失败。' -f $fail) -ForegroundColor Red
exit 1
