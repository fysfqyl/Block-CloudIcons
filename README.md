# 禁止“此电脑”里出现网盘图标

装完百度网盘、阿里云盘、夸克、OneDrive、坚果云这类软件后，它们常常会往资源管理器的**“此电脑”**（老系统叫“我的电脑”）里塞一个图标。
这个脚本做三件事：

1. **清理**已经存在的这类图标；
2. **阻止**当前用户再往这个位置新建图标（注册表权限拒绝）；
3. **守护**：装一个以 SYSTEM 身份运行的计划任务，定时把新冒出来的图标清掉——包括以管理员身份运行的安装程序偷偷写进去的。

任何删除动作之前都会先把整段注册表**导出备份**，可以一条命令还原。

---

## 快速开始

1. 把 `Block-CloudIcons.ps1`、`Block-CloudIcons.cmd` 放在同一个文件夹里（放在桌面或任意固定目录，别放在临时目录）。
2. **双击 `Block-CloudIcons.cmd`**，出现菜单后按数字选择。
3. 建议先选 `1` 扫描看看，再选 `4` 开启防护。开启防护时会弹出 UAC 提权提示，点“是”。

> 做完一项操作后按回车会回到菜单，选 `0` 退出。

> 只想要一次性清理、不要常驻守护：选 `3` 即可。
> 想自己挑哪些删、哪些留：选 `2`。
> 想撤销全部改动：选 `6` 取消防护。

Windows 10 / 11 自带的 PowerShell 5.1 就能跑，不需要装任何东西。

---

## 菜单与命令行

双击启动是交互菜单；也可以直接用命令行：

| 操作 | 命令 |
| --- | --- |
| 扫描（只读，不改动） | `powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Scan` |
| 手动挑选要清理/保留的图标 | `powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Pick` |
| 立即清理 | `powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Clean` |
| 开启防护 | `powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Protect` |
| 查看状态 | `powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Status` |
| 取消防护 | `powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Unprotect` |
| 从备份恢复 | `powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Restore` |
| 查看/清空保留名单 | `powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Keep` |

常用参数：

| 参数 | 说明 |
| --- | --- |
| `-Pick` | 等价于 `-Action Pick`，手动挑选要清理的项 |
| `-SelectIds "1,3-5"` | 配合 `-Pick`，不交互、直接按序号挑选（序号就是清单里显示的数字） |
| `-ClearKeep` | 配合 `-Action Keep`，清空“手动保留名单” |
| `-DryRun` | 只演示，不写注册表、不建任务（清理/挑选/防护/恢复都支持） |
| `-IncludeDesktop` | 连“桌面”命名空间一起查（默认只查“此电脑”） |
| `-AllUnknown` | 把“来源不明”的第三方项也当作要清理（默认只留不删） |
| `-Keep <字符串>` | 白名单，命中名称/显示名/DLL 路径的项永不删除，可写多个 |
| `-IntervalMinutes <n>` | 守护任务多久跑一次，默认 5 分钟 |
| `-NoGuardAcl` | 只装守护任务，不加注册表拒绝规则 |
| `-RestoreFrom <目录>` | 指定从哪个备份目录恢复（默认最近一次） |
| `-Quiet` | 静默模式，只写日志（守护任务内部使用） |

例子：

```powershell
# 先看会删哪些，什么都不改
powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Clean -DryRun

# 手动挑：只看会删什么、再决定删哪几个
powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Pick

# 不交互，只删清单里第 1、3、4 项
powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Pick -SelectIds "1,3-4"

# 保留“坚果云”，其余网盘图标清掉并开启每 10 分钟一次的守护
powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Protect -Keep 坚果云 -IntervalMinutes 10

# 桌面上如果有网盘图标也一起管
powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Protect -IncludeDesktop
```

---

## 手动挑选：只清一部分，其余留着

菜单选 `2`（或命令行 `-Pick`）。脚本会把扫描到的项编号列出来，你输入序号就可以了：

```
  序号  位置           标识                                    名称      判定    依据
  1     HKCU · 此电脑  {679F137C-3162-45da-BE3C-2F9C3D093F64}  百度网盘  待清理  命中网盘关键词
  2     HKCU · 此电脑  {6FCBEFA0-DD11-4EB0-A87D-46DAF26BF2B7}  夸克网盘  待清理  命中网盘关键词
```

输入方式：

| 输入 | 含义 |
| --- | --- |
| `1` | 只清理第 1 项 |
| `1,3-5` | 清理第 1 项和第 3~5 项（逗号、空格、分号、顿号都行） |
| `all` | 清掉清单里的全部（会二次确认） |
| `none` | 一个都不清 |
| `a` | 显示/隐藏“系统项”，想连系统项一起看时用（删系统项前会警告） |
| `q` | 取消 |

**编号只对应“当前显示的清单”**：默认只列“待清理/来源不明”的项，按 `a` 展开系统项后编号会重新从 1 排起。

删完之后脚本会问一句“**把没选中的项加入保留名单？**”：

- 选“是”：这些项的名字会写进 `%ProgramData%\NoCloudIcons\state.json` 的 `KeepExtra` 里，**以后的自动清理和定时守护都不会再动它们**（这是关键——否则你手动留下的图标，5 分钟后就被守护任务删了）；
- 选“否”：什么都不记，下次自动清理时照样按判定规则处理。

想看现在留了什么、或者全部解除：菜单选 `8`，或命令行 `-Action Keep` / `-Action Keep -ClearKeep`。

> `-SelectIds` 适合做批处理/自动化：不弹提问、不问确认，直接按序号删。

---

## 判定规则

脚本只动 `Explorer\MyComputer\NameSpace`（可选 `Explorer\Desktop\NameSpace`）下面的子键，
按下面的顺序判定，第一命中即生效：

| 顺序 | 条件 | 结果 |
| --- | --- | --- |
| 1 | 命中 `-Keep` 白名单，或命中“手动保留名单”（`state.json` 里的 `KeepExtra`，见上一节） | 保留 |
| 2 | CLSID 属于 Windows 内置项（下载/文档/图片/音乐/视频/桌面/此电脑/控制面板/回收站/用户文件夹/库/网络等） | 保留 |
| 3 | CLSID 名、命名空间里写的显示名、`DefaultIcon` 图标路径、DLL 路径、资源字符串里出现“网盘/云盘/百度网盘/OneDrive/Dropbox/坚果云/夸克/MEGA”等特征词 | 删除 |
| 4 | DLL 在 `C:\Windows` 下，且没有任何第三方痕迹 | 保留（系统组件） |
| 5 | 在“此电脑”位置，且有第三方痕迹（图标不在系统目录、命名项自带名称、CLSID 只注册在 HKCU、DLL 不在系统目录） | 删除（“第三方命名空间”） |
| 6 | 在“桌面”位置、有第三方痕迹，且加了 `-AllUnknown` | 删除 |
| 7 | 其余 | 标记“来源不明”，**不删**，只在扫描结果里列出来 |

两条容易踩坑的地方，脚本已经专门处理：

- **特征词排在“DLL 在系统目录”之前**。有些网盘（例如百度网盘）故意让 `InprocServer32` 指向 `shdocvw.dll`、`shell32.dll` 这些系统 DLL，如果先按 DLL 位置判断，它就会被当成系统组件漏掉。脚本还会读 `DefaultIcon`（常常直接写着 `D:\BaiduNetdisk\netdisk_logo.ico`）和命名空间子键里写的“百度网盘”来认它。
- **“此电脑”位置比“桌面”位置严格**。往 `此电脑` 根节点塞图标的第三方软件几乎只有网盘/云盘，所以只要看出是第三方写的就删；`桌面` 下的系统文件夹多（文档、搜索、CSC 缓存等），所以那里默认只标“来源不明”，要删得加 `-AllUnknown`。

也就是说：**不确定的一律不动**，你能在扫描结果里看到它们，确认无害后再用 `-AllUnknown` 处理。

`DelegateFolders`（“此电脑”里那几个固定的系统文件夹）永远跳过。

---

## 防护是怎么做到的

| 层 | 手段 | 挡得住什么 |
| --- | --- | --- |
| 1 | `HKCU\...\MyComputer\NameSpace` 上加一条**拒绝“创建子键”**的权限规则（只拒绝新建，不影响删除） | 普通权限的软件往当前用户这里加图标 |
| 2 | 计划任务 `NoCloudIconsGuard`，以 `NT AUTHORITY\SYSTEM` 身份、每 N 分钟运行一次 `run-guard.cmd`（内部调用 `-Action Clean -Quiet -Scheduled`），清理所有用户的 `HKU\S-1-5-...\...\NameSpace` | 需要管理员权限才能写的 `HKLM` 项，以及已经写进去的残留项 |
| 3 | 每次删除前 `reg export` 备份 + 写 `manifest.json` | 误删可回滚 |

因为第 2 层对所有用户生效，所以**别的账户登录后**新出现的图标也会被清掉。

---

## 备份、日志、安装位置

| 内容 | 位置 |
| --- | --- |
| 备份 | `%ProgramData%\NoCloudIcons\Backup\<时间戳>\*.reg` + `manifest.json`（只保留最近 20 份） |
| 安装的脚本副本 | `%ProgramData%\NoCloudIcons\Block-CloudIcons.ps1`（守护任务跑的是这份，原文件删了也不影响） |
| 守护任务的启动脚本 | `%ProgramData%\NoCloudIcons\run-guard.cmd`（计划任务实际调用它，由它再调用上面的 .ps1） |
| 操作历史 | `%ProgramData%\NoCloudIcons\history.log` |
| 守护任务日志 | `%ProgramData%\NoCloudIcons\guard.log` |
| 状态文件 | `%ProgramData%\NoCloudIcons\state.json`（守护任务配置 + 手动保留名单 `KeepExtra`） |

恢复：`-Action Restore` 会导入最近一次备份；也可以手动双击备份里的 `.reg` 文件，或指定目录：

```powershell
powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Restore -RestoreFrom "C:\ProgramData\NoCloudIcons\Backup\20250101-120000"
```

> 防护还开着时，当前用户命名空间仍处于“拒绝创建子键”状态，写在那里的项目会恢复失败。
> 想完整还原，先 `-Action Unprotect`，再 `-Action Restore`。
> 另外：清理时如果有哪一项**备份失败**，脚本会跳过它、绝不动手，汇总里会单独显示“跳过 N 个”。

---

## 完全卸载

1. 运行 `-Action Unprotect`（或菜单选 `6`）：删掉守护任务、撤销权限规则。
2. 想彻底干净，再手动删除 `C:\ProgramData\NoCloudIcons` 文件夹。
3. 已经删掉的图标不会自己回来；要还原就先用 `Restore` 恢复，再执行第 1、2 步。

---

## 常见问题

**Q：提示“此操作需要管理员权限”？**
清理、开启/取消防护、恢复都需要管理员权限，脚本会自动弹 UAC；如果 UAC 被取消，就右键 `Block-CloudIcons.cmd` →“以管理员身份运行”。

**Q：为什么扫描结果是空的，但“此电脑”里明明有图标？**
先加 `-IncludeDesktop` 试试；另外有些软件用的是“网络位置”而不是命名空间项，那种不在本脚本处理范围内。

**Q：取消防护（`-Action Unprotect`）跑完，`-Action Status` 还显示“已禁止当前用户创建子键”？**
v1.3 及更早版本的 bug：撤销时用了 `$acl.RemoveAccessRuleSpecific($rule)` 的返回值做判断，而 .NET 里这个方法返回的是 **void**，判断永远为假 → 权限规则在内存里删掉了却没写回注册表 → 屏幕上一行提示都没有，看起来“撤销了”，其实没撤。
v1.4 已修：改成按“删除前后 ACE 条数”判断，并在结尾**重新读一遍注册表复核**；撤不干净会明确打红字，并把该键的 DACL 打出来便于定位。
碰到过这个 bug 的，直接用新版重跑一次 `-Action Unprotect` 即可（新版不依赖 `state.json`，会老老实实扫当前用户的命名空间键）。

**Q：开启防护时报 `The task XML contains a value which is incorrectly formatted or out of range`？**
这是 v1.2 及更早版本的已知问题（生成的任务定义里有个“无限重复”的时长写成了 `P99999999DT23H59M59S`，任务计划不认）。v1.3 起改用 `schtasks` 命令行注册、按“每 N 分钟”调度，不再出现这个报错。
如果你之前踩到过，当前可能是“权限规则已加、守护任务没装、状态文件也没写”的半残状态，按下面两步收拾即可。

**Q：提示“守护任务注册失败”，但权限加固已经生效了？**
从 v1.3 起这是可以接受的中间状态：`“禁止新增图标”` 那一层已经生效，只是“定时清理”没装上，脚本会把这条写进 `history.log` 并继续保存状态。
收拾办法：

```powershell
powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Unprotect
powershell -ExecutionPolicy Bypass -File .\Block-CloudIcons.ps1 -Action Protect
```

`Unprotect` 与状态文件无关（它直接遍历当前用户的命名空间键撤掉拒绝规则），所以即便是刚才那种半残状态也能一键清干净，再 `Protect` 就是全新安装。

**Q：更新了脚本以后，守护任务跑的还是旧版本吗？**
是。守护任务跑的是 `%ProgramData%\NoCloudIcons\` 里的**副本**，换新脚本后要重跑一次 `-Action Protect` 覆盖它；`-Action Unprotect` 会把副本一并删掉。

**Q：手动留下的图标，会不会过一会儿又被守护任务删掉？**
不会。挑选时选择“把没选中的项加入保留名单”，它们的 CLSID 就写进 `state.json` 了，自动清理和守护任务都会跳过它们。要解除用菜单 `8` 或 `-Action Keep -ClearKeep`。

**Q：加了防护以后想临时装个网盘软件试试？**
先 `-Action Unprotect`，装完再 `-Action Protect`。

**Q：会不会把系统自带的“下载”“文档”删掉？**
不会。Windows 内置 CLSID 表的项一律保留（`下载/文档/图片/音乐/视频/桌面` 都在表里），`C:\Windows` 下、没有任何第三方痕迹的项也保留。
“此电脑”里若有第三方软件写的命名空间项，脚本会判为“第三方命名空间”并删除——每次删除前都会 `reg export` 备份，用 `-Action Restore` 可以原样恢复；想长期保留某个项，用 `-Keep <关键字>` 加白名单。

**Q：脚本会不会联网、上传东西？**
不会。纯本地注册表操作 + 计划任务，没有任何网络访问。

---

## 风险提示

- 脚本会修改注册表和计划任务，请先跑一次 `-Action Clean -DryRun` 看清楚要动哪些项。
- 所有删除都有 `.reg` 备份，最坏情况也能 `Restore` 回来。
- 在极少数系统上，第三方 shell 扩展图标未必写在命名空间键里，脚本无法覆盖全部来源，但能覆盖绝大多数网盘软件的做法。

---

## 发布到 GitHub（可选）

项目自带 `Publish-ToGitHub.ps1`，用 GitHub REST API 建仓库并逐文件上传，**不需要安装 git 或 gh**。

1. 生成 Token：打开 <https://github.com/settings/tokens/new>，Note 随便填，勾选 `repo` 整块，生成后复制 `ghp_` 开头那串。
2. 先看会传什么（不联网、不改动任何东西）：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Publish-ToGitHub.ps1 -DryRun
   ```

3. 正式上传（会提示粘贴 Token，输入内容不显示）：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Publish-ToGitHub.ps1
   ```

   常用参数：`-RepoName 别的名字`、`-Private`（私有仓库）、`-Force`（仓库已存在时往里覆盖文件）。

上传内容：`Block-CloudIcons.ps1`、`Block-CloudIcons.cmd`、`README.md`、`.gitignore`、`tests\*.ps1`。
Token 只在内存里用，不会写进文件、也不会打印出来；用完可以在 GitHub 设置里 revoke。

