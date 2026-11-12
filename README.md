<p align="center">
  <img src="docs/images/app-icon.png" width="120" alt="3106">
</p>

<h1 align="center">3106</h1>

<p align="center">
  无越狱的 iOS 容器管理工具：应用数据、补丁、清理、壁纸与拨号主题。
</p>

<p align="center">
  <a href="README.en.md">English</a> ·
  <a href="CHANGELOG.md">更新日志</a> ·
  <a href="docs/PATCH_GUIDE.md">补丁指南</a>
</p>

## 项目信息

| 项目 | 内容 |
| --- | --- |
| 当前版本 | **3.2.3**（正式版） |
| 当前发布 | **v3.2.3**（build 21，修复 .tendies 真机导入 noDescriptors：路径包含不再依赖软链解析） |
| 支持系统 | iOS 17.0–18.7.1 · 26.0–26.7.2 · 27.0–27.3（已验证） |
| 访问后端 | kernel / `bad_query` / `worse_query`（按系统版本自动选择） |
| 界面语言 | 简体中文 · English · Tiếng Việt |
| 签名要求 | iOS 26.7+ / 27.x 需要 App Group entitlement |
| Bundle ID | `com.qingtang.3106` |
| 仓库 | <https://github.com/QuinnTang74/3106.git> |

## 功能

| 模块 | 说明 |
| --- | --- |
| MobileGestalt 卡片页 | Erosion 风格：暂存开关 + 右上“应用”统一写入、Apple 智能四要素体检（配置 vs 真机对比）、一键恢复原厂、31 条预设（显示/设备/iPad/智能/高级）、锁定态与出厂基线保护 |
| CacheExtra 字段编辑器 | 8 种类型（含 Array/Dictionary XML 片段）、搜索/增删改、plist 导入导出、类型保真 |
| 区域与 Siri AI | 区域三元组 + 监管型号（已核实机型表）、原生 Siri AI / 实验模式、防重启反弹 |
| 任意文件替换 | 选应用→逐级浏览容器目录→选文件→可选备份→替换；替换记录持久化、一键恢复备份、预设保存一键选用；受保护系统路径护栏 |
| 监管模式 | Supervised Mode 开关（ConfigurationProfiles，MDM 警告 + 风险确认） |
| 应用存档备份 | Documents + Library/Preferences 打包 `.3106save`，重装后按 bundleID 重匹配容器还原 |
| 备份 tab（一级页） | 自动备份说明、快照总览、全量备份 `.3106fullbackup`（含清单、一键恢复）、存档预览、操作时间线 |
| 清理器 | 安全纵深（16 条黑名单 + dev/ino 身份重校验 + 三段确认门）、测量预算制 + 增量缓存、逐应用进度、累计统计 |
| 文件浏览 | 应用容器逐级导航、体积列与排序、索引时间标注、AppCard 卡片行、Hex/Plist/SQLite 工具 |
| 应用枚举提速 | LaunchServices 数据库直读（含 iOS 26.5 布局）、MCM 并行激活、pathleak 动态上界、扫描诊断日志 |
| 壁纸与拨号主题 | `.tendies` PosterBoard 壁纸（已并入功能页）、拨号键主题（逐文件备份/恢复） |
| 软件源 | AltGallery 唯一默认源（AltStore 格式适配器，61 个 App），IPA 下载后交分享面板签名 |
| 更新检查 | 启动自动检查 + 设置页手动检查，新版本跳转 GitHub Releases |
| 风险体系 | 每个写入功能三段式风险说明 + 全屏红色确认（长按 1.2 秒）+ 版本受限红字横幅 |
| 三语言界面 | 简体中文、English、Tiếng Việt |

## 最近更新

| 版本 | 主要内容 |
| --- | --- |
| **3.2.3** | 正式版：修复 `.tendies` 真机导入全部失败 noDescriptors（issue #2：路径包含检查不再依赖软链解析，/var 与 /private/var 任意拼写组合均接受） |
| **3.2.2** | 正式版：修复 MobileGestalt 卡片页暗黑模式（卡片底色改为动态语义色，暗色主题下不再白底白字） |
| **3.2.1** | 正式版：四要素体检状态图标（未修改=中性/已改=绿勾/不匹配=警告，iOS 26 全红叉）、替换文件预设保存与一键选用、横幅判定修正（内核后端可达系统组）、替换页撤横幅、设置页检查更新 |
| **3.2.0** | 正式版：全量功能对齐（详见上方功能表与 CHANGELOG）；WQFiles 0.9.1 的 iOS 26.5 布局同步；iOS 27.3 beta 1 转正式支持；AltGallery 软件源；Erosion-CN v0.8.5 出厂基线保护；致谢扩至 9 项 |
| **3.1.13** | 功能主页 + 固定 5 项底栏；LaunchServices 快速目录；备份中心与安全写入；扫描进度/停止；MobileGestalt 安全子集、拨号键主题；SQLite/Hex/Plist 文件工具 |
| **3.1.12** | 正式版：修复壁纸导入/扫描、已安装最新版仍提示更新、清理切文件页卡顿；包含 3.1.8–3.1.11 的全部修复 |
| **3.1.11** | 测试构建：直接用已成功的 tree 枚举收集 descriptors，避免早期枚举被沙箱挡住；导入增加 extracting/extracted/inspected 阶段日志；启动日志显示版本号 |
| **3.1.10** | 测试构建：修复 `.tendies` 解包后 `isContained` 的 `/var` 与 `/private/var` 误判；设备端 descriptor 改用枚举器优先，解决“树里有目录、扫描说没有” |
| **3.1.9** | 测试构建：壁纸扫描强制 `/private/var`；ZIP 支持 GB18030 文件名、反斜杠路径、重复目录和 768MB 视频条目；文件页复用 LS/文件系统缓存并跳过冗余 MHA 扫描 |
| **3.1.8** | 修复已安装最新版仍提示更新；修复清理扫描时切底栏卡死；修复壁纸扫描的 `/var` 路径拼写导致看不到 descriptors，并补充导入错误日志 |
| **3.1.7** | 壁纸：修复 27.3 布局扫描提前失败、Mercury 目录名、视频 descriptor 映射与散装 descriptor 包；清理器改为逐应用刷新并显示已加载数量 |
| **3.1.6** | 收藏夹：长按文件夹收藏，文件标签页顶部直接列出收藏路径；兼容 3105 2.0 的收藏数据 |
| **3.1.5** | 应用数据浏览器恢复全部容器：移除 MHA 硬门禁、LaunchServices `bdsl` 解析、未识别容器单独分组且只读 |
| **3.1.4-r2** | 项目地址迁移至 **QuinnTang74/3106**；应用内 GitHub 入口、更新检查与 README 同步 |
| **3.1.4** | 清理删除改用扫描记录的真实容器路径；`FileManager` 安全删除并拒绝跳出容器的符号链接 |
| 3.1.3 | 壁纸扫描器支持 27.3 的嵌套/非标准 PosterBoard 布局，按需创建扩展 descriptors 目录 |
| 3.1.2 | 清理测量改用 `FileManager` 枚举；壁纸按 PosterBoard 存储目录反查容器；清理页常驻设置齿轮 |
| 3.1.1 | 清理器加入文件系统枚举与容器索引回退；壁纸扫描/探针/安装/重置逐目录授权 |
| 3.1.0 | 底栏配置、默认开发者模式、移除推广与致谢、中文 README |

完整记录见 [CHANGELOG.md](CHANGELOG.md)。

## 3.2 版本详情

### MobileGestalt 卡片页（Erosion-CN 同款交互）

- 暂存开关 + 右上「应用」统一写入；行下显示「已暂存」状态，可整体放弃。
- Apple 智能激活四要素体检：销售地区 / 美版监管型号 / 国行门控 / 端侧 AI 准入，每行「配置 vs 真机实时」对比；状态图标未修改 = 中性、已改且匹配 = 绿勾、不匹配 = 橙色警告、iOS 26.0–26.6.1 全红叉。
- 顶部状态卡：真机核验入口 + 双重原厂备份说明 + 一键恢复原厂（带确认）。
- 31 条预设（显示 / 设备 / iPad / 智能 / 高级五类）；锁定态开关（原生已开启 = 浅绿锁定防误关；出厂基线保护 = 橙色锁定）。
- CacheExtra 字段编辑器：8 种类型、plist 导入导出、类型保真（CFBoolean / CFNumberIsFloatType 精确分型）。

### 任意文件替换（新模块）

- 选应用 → 逐级浏览容器目录 → 选文件 → 勾选「替换前备份原文件」→ 替换；iOS 26 与 27 双后端可用。
- 替换记录持久化（重启仍在），一键恢复备份；恢复前当前文件自动改名暂存。
- 替换预设：保存应用+路径组合，下次一键选用；删除操作强制备份。
- 受保护系统路径护栏：Gestalt 缓存 / 配置描述文件 / 钥匙串等拒绝裸替换。

### 备份中心（一级 tab）

- 底栏五项：功能 / 文件 / 搜索 / 清理 / 备份；壁纸并入功能页。
- 全量备份 `.3106fullbackup`：Gestalt 缓存 + 配置描述文件 + 补丁工作区 + 快照索引，含清单与逐项恢复前自动再备份。
- 应用存档备份：Documents + Library/Preferences 打包 `.3106save`，重装后按 bundleID 重匹配还原。
- 操作时间线：备份 / 恢复 / 清理 / 写入四类事件统一记录。

### 区域与 Siri AI

- 区域三元组（LL/A）+ 监管型号自动匹配（已核实机型表）；只写设备已有键防重启反弹。
- 原生 Siri AI（不伪装硬件）/ 实验模式（伪装 + SiriMode=2，iOS 27+，未知机型拒绝）。
- 出厂基线保护：Audio Intelligence 出厂为 false，强开会破坏照片高质量消除（Erosion-CN v0.8.5 真机验证）。

### 系统级与清理器

- 监管模式（Supervised Mode）开关；应用存档备份；系统容器快捷入口。
- 清理器安全纵深：16 条受保护路径黑名单、(dev,ino) 身份重校验、三段确认门；测量预算制 + 增量缓存；逐应用清理进度；累计统计。
- 扫描提速：MCM 并行激活、lsd 目录并行探测、pathleak 动态上界、扫描诊断日志（watchdog）。
- 软件源：AltGallery 唯一默认源（AltStore 格式适配器），IPA 下载后交分享面板签名。
- 更新检查：启动自动 + 设置页手动；风险体系：三段式说明 + 全屏红色确认 + 版本受限红字横幅。

### 已知限制

- 整包应用备份（含 Library 全量）未实现；存档备份覆盖 Documents 与 Library/Preferences。
- iPadOS 二进制 CacheData 修改（Erosion 同款）未实现。
- 性能数字需真机采集；`scan-diag-latest.log` 可在文件页与日志页查看。

## 兼容性

| 系统 | 已验证范围 | 访问后端 |
| --- | --- | --- |
| iOS 17 | 17.0–17.7.x | 内核链路 |
| iOS 18 | 18.0–18.7.1 | 内核链路 |
| iOS 26 | 26.0–26.7.2 | `worse_query` (App Group) |
| iOS 26 | 26.0–26.6.1 | `bad_query` (fallback) |
| iOS 27 | 27.0–27.3 beta 1 | `worse_query`（27.3 已真机验证，正式支持） |

> iOS 17/18 仍需手动启用内核链路；iOS 26/27 不涉及内核漏洞。System Data 在 iOS 27 上仅可列目录。

## 安装与签名

| 签名方式 | App Group | 说明 |
| --- | --- | --- |
| AltStore / SideStore / Sideloadly + Apple ID | 自动创建 | 推荐；免费 Apple ID 即可 |
| 自有开发者账号 | 需显式 App ID + App Groups 能力 | 在开发者后台创建专用 profile |
| 证书（`.p12`）+ 通配符 profile | 不支持 | `worse_query` 会报 “No App Group” |
| LiveContainer | 取决于签名环境 | 在应用内 **设置 → App Group** 检查 |

使用证书与描述文件时，描述文件必须是包含 **App Groups** 能力的显式 App ID；通配符 profile 无法携带 App Group。

## 构建与测试

| 任务 | 命令 |
| --- | --- |
| 无签名构建 | `xcodebuild -project ThreeOneOSSix.xcodeproj -scheme 3106 -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build` |
| 策略测试 | `bash Tests/run_policy_tests.sh` |
| 产物目录 | `dist/`，本次文件名 `3106-3.2.3-unsigned.ipa` |

## 下载

正式版发布在 GitHub Releases：

<https://github.com/QuinnTang74/3106/releases>

发布资产为未签名 IPA，需要按上面的签名方式自行签名后安装。

当前版本：`3106-3.2.3-unsigned.ipa`（SHA256 `4f47344764422731bd33b77f3aad8d39d25f67ef8a564bee9e2c5ced0d4c6fae`）。

## 开源协议与商用说明

本仓库整体以 **GNU GPL v3.0** 发布，完整文本见 [LICENSE](LICENSE)。

项目包含来自 3105、`worse_query`、WQ Files 等 GPL-3.0 代码。GPL-3.0 不允许再附加“禁止商用”一类额外限制，因此不能把整体改成严格意义上的非商用协议。

作者不希望本项目被用于商业用途；如需商用，请先联系仓库作者。这句话是作者意愿说明，不构成对 GPL-3.0 的额外限制，也不改变上游及第三方代码的许可。

二次修改或再分发时，必须保留 [LICENSE](LICENSE) 与 [NOTICE.md](NOTICE.md) 中的版权、来源和许可声明，并注明你做了哪些修改；这是 GPL-3.0 的要求，也是本项目的要求。

## 参考项目

本项目参考并基于 **3105 项目**（原作者 YangJiii）的 2.0 源码；iOS 27 适配、`worse_query` 移植、清理器与壁纸修复、3106 改名均在此基础上完成。第三方代码的版权与来源声明见 [NOTICE.md](NOTICE.md)（GPL-3.0 要求，不是推广内容）。