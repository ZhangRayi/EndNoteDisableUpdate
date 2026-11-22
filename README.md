# EndNote 自动更新拦截工具（Windows）

EndNote 的更新提示很烦，升级后还容易出问题。这个工具包把「检查更新」这条路直接封掉，
以后 EndNote 启动时不会再联网找新版本，也不会再弹窗劝你升级。

## 先说结论：它做了什么

EndNote 启动后会用明文 HTTP 请求：

```
http://download.endnote.com/updates/<大版本>/EN<大版本>WinUpdates.xml
```

（例如 22.0 版就是 `.../updates/22.0/EN22WinUpdates.xml`）

拿到版本清单后，只要发现比本机新，就弹窗问要不要装。工具包做三件事：

1. **hosts 屏蔽** `download.endnote.com` → 指向本机（IPv4 + IPv6），这是真正生效的一层；
2. **机器级开关**：`HKLM\SOFTWARE\WOW6432Node\ISI ResearchSoft\EndNote\<版本>\USERCANAPPLYUPDATES = no`；
3. **用户级偏好**：`HKCU\...\EndNote\Preferences` 里 `CheckForUpdate`、`UserCanApplyUpdates` 置为 `F`。

> 实测第 3 条单独拦不住（EndNote 照样联网检查），真正起作用的是第 1 条 hosts，
> 第 2、3 条是「万一检测到了也装不上」的兜底。

## 怎么用

1. 把**整个文件夹**拷到电脑上任意位置（别只拷单个 .ps1，两个文件要放在一起）；
2. **先退出 EndNote**；
3. 双击 `一键阻止EndNote更新.cmd`；
4. 弹出的「用户账户控制」点 **是**；
5. 看到「完成」和一行行 `[完成]` 就好了，按回车关闭。

以后想恢复自动更新：双击 `一键恢复EndNote更新.cmd`，同样允许管理员权限。

## 会不会有副作用

- 只屏蔽 `download.endnote.com` 一个域名。受影响的是：EndNote 帮助菜单里几个指向该域名的 PDF/培训链接打不开，手动点「Check for Updates」会报错。
- **不受影响**：EndNote 同步（myendnoteweb.com）、在线检索、Find Full Text、Word 插件。
- 不改 EndNote 程序文件，不涉及破解/替换文件，随时可还原。
- 脚本每次运行都会先把原 hosts 和注册表导出到桌面 `EndNote更新拦截备份` 文件夹，出问题可以手工恢复。

## 命令行用法（可选）

```powershell
# 阻止
powershell -NoProfile -ExecutionPolicy Bypass -File .\EndNote-BlockUpdate.ps1

# 恢复
powershell -NoProfile -ExecutionPolicy Bypass -File .\EndNote-BlockUpdate.ps1 -Undo
```

参数：

| 参数 | 作用 |
| --- | --- |
| `-Undo` | 解除封锁，恢复自动更新 |
| `-SkipBackup` | 不备份（不建议） |
| `-NoElevate` | 不自动请求管理员权限（会失败，调试用） |
| `-KeepWindowOpen` | 结束后等回车（.cmd 启动器已自动带上） |

## 以后想升级 EndNote 怎么办

1. 先运行 `一键恢复EndNote更新.cmd`；
2. 去官网下载**完整安装包**手动安装（别用程序里的 Download and Install）；
3. 装完再运行一次 `一键阻止EndNote更新.cmd`。

> 重新安装或修复安装 EndNote 后，安装程序可能把 `USERCANAPPLYUPDATES` 重置成 `yes`，
> 所以装完建议重跑一次本工具。

## 兼容性与常见问题

- 系统：Windows 10 / 11，使用系统自带的 PowerShell 5.1 或更新版本。
- 版本：EndNote 20 / 21 / 2025（32 位安装，注册表在 WOW6432Node 下）。脚本会自动找所有版本子键。
- Mac 版 EndNote 请不要用这个包（这是 Windows 脚本）。
- 杀毒软件提示「修改 hosts 文件」：属误报性质，允许即可；脚本已做备份。
- 双击一闪而过：右键 .cmd → 以管理员身份运行；或按上面命令行方式跑，能看到完整报错。
- 提示「无法修改 hosts」：检查 hosts 是否被设了只读，或安全软件锁定了该文件。
