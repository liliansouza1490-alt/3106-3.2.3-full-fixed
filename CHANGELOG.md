# Changelog

All notable user-facing changes are documented in this file.

## [3.2.3] - 2026-11-12

### Fixed

- `.tendies` 导入在真机上全部失败 `noDescriptors`（issue #2）：路径包含检查此前依赖 `resolvingSymlinksInPath()`，沙盒内该调用可能提前返回，使 `/var` 与 `/private/var` 两种拼写无法归一，descriptors 目录被整棵跳过。现在比较接受两侧任意 raw/resolved 拼写组合，不再依赖软链解析；导入入口统一解压根的路径形态；skip 日志同时打印解析前后路径。

## [3.2.2] - 2026-11-12

### Fixed

- MobileGestalt 卡片页暗黑模式：卡片底色此前写死为白色，暗色主题下白底白字不可读；改为动态语义色（浅色主题白卡、暗色主题深灰卡），药丸按钮同步修正。

## [3.2.1] - 2026-11-12

### Added

- MobileGestalt 四要素体检状态图标：未修改 = 中性减号圈、已写入且匹配 = 绿勾、不匹配 = 橙色警告；iOS 26.0–26.6.1（bad_query，无写入通道）四行直接红叉。
- 任意文件替换预设：保存应用+路径+备份勾选组合为命名预设（上限 50，持久化），下次一键选用；同一目标重新保存即更新。
- 设置页「检查更新」：手动检查绕过"忽略此版本"记忆，直接报告最新 Release；启动时的自动检查保持不变。

### Fixed

- 后端可达性判定：内核后端（iOS 17/18）完全逃出沙盒、系统组可达，此前会被误标"功能受限"红字；现在只有 bad_query（26.0–26.6.1）不可达。
- 任意文件替换页撤除红字横幅：应用容器内的替换在 iOS 26 与 27 均可用，常驻横幅属于噪音；系统组目标的拒绝理由由服务层按次返回。

## [3.2.0] - 2026-11-11

### Added

- 清理器安全纵深：受保护系统路径黑名单（16 条，组件级前缀匹配）、清理前 (dev,ino) 身份重校验（防扫描→清理之间容器被替换）、三段式确认门、逐子项符号链接容器内校验；清理白名单保持 `Library/Caches` + `tmp` 不变。
- 清理器体积测量预算制：单容器 12000 项 / 0.25 秒上限，超限进入延迟队列，列表先出、体积后补；新增按目录 mtime 的增量体积缓存，未变化目录直接复用上次结果。
- 清理历史与累计统计：清理页显示"累计已释放"，每次清理写入历史记录（时间/应用数/字节数/失败数）。
- 文件页体积列与排序切换（名称/体积）、索引时间标注（"索引 · X 分钟前更新"）、容器体积后台并行测量；统一 AppCardRow 卡片行组件（主标题 + 等宽 bundleID·体积 副标题）。
- 全屏红色风险确认组件：三段式风险说明（会发生什么 / 最坏情况 / 怎么恢复）+ 长按 1.2 秒确认；合成音效系统（点击/确认/警告/成功/失败，设置页可关）。
- 底栏调整：壁纸并入功能页，新增"备份"tab——自动备份说明、快照总览与管理入口、全量备份（`.3106fullbackup`：Gestalt 缓存 + 配置描述文件 + 补丁工作区 + 快照索引，含清单，一键恢复）、应用存档预览、跨功能操作时间线（备份/恢复/清理/写入）。
- MobileGestalt 预设库：31 条预设覆盖显示 / 设备 / iPad / 智能 / 高级五类（键名与 GestaltX/MGKeys/Nugget/mond 交叉核对）；设备上不存在的键一律禁用并说明原因（防 iOS 27 重启反弹）；Advanced 类强制全屏红色确认。
- CacheExtra 字段编辑器：搜索/新增/编辑/删除、8 种类型（String/Integer/Real/Boolean/Data/Date/Array/Dictionary）、plist 导入导出；类型保真（`CFBooleanGetTypeID()` / `CFNumberIsFloatType()` 精确分型，布尔保持布尔、浮点保持浮点）。
- 区域与 Siri AI：区域快照展示；已核实机型表的原生 Siri AI（只改国家码/销售区域/监管型号 + AI 旗标，不伪装硬件）；实验模式（伪装 product/board/CPU + SiriMode=2，仅 iOS 27+，未知机型拒绝写入，默认隐藏在"实验功能"开关后）；LL/A 区域修改。
- 监管模式（Supervised Mode）开关：读/写 ConfigurationProfiles 容器的 `IsSupervised`，MDM 警告常驻，写入走验证管线并自动备份。
- 应用存档备份：打包 Documents + Library/Preferences 为 `.3106save`（含清单），重装后按 bundleID 自动匹配新容器还原（拒绝路径穿越、还原前自动安全快照、受保护应用拒收）。
- 扫描提速：MCM 容器激活并行化（并发 6）、lsd 守护容器目录并行探测、pathleak 动态 inode 上界（按实际分配水位收窄 200 万固定爆破区间）、扫描诊断日志（专用线程 `write(2)` + 5 秒 watchdog 心跳，`Documents/scan-diag-latest.log`）。
- 结构化 Plist 编辑器类型保真修复：Integer/Real 分型，浮点值（如相机变焦）不再被写回整数。
- 风险说明体系：每个新功能附带"会发生什么 / 最坏情况 / 怎么恢复"三段说明（功能页 + 风险确认页 + `docs/RISKS.md` 汇总）。
- 出厂基线保护（同步 Erosion-CN v0.8.5 真机发现）：Audio Intelligence 出厂全为 false，强行开启会断路照片"高质量"消除的云端管线——该预设锁定并说明；Siri AI 实验模式对出厂 false 的 AI 旗标拒绝写入。
- 体验修复：预设开关从 4-6 次全量 plist 解析降到 1-2 次；文件浏览器目录体积加预算（12k 项/0.5s，超大目录显示截断标记）；清理过程显示逐应用进度（清理中 N/M · 已释放 · 当前应用）；QuickLook 预览加 200MB 上限（原为无限拷贝，大视频假死 30 秒）。
- 本地化对齐门禁：`Tests/check_strings_alignment.sh` 校验三语键集一致（1108 键 × 3）；全部新功能文案三语补齐。
- 真机验收清单：`docs/releases/device-checklist-3.2.md`。

### Changed

- 底栏从 功能/文件/搜索/清理/壁纸 改为 功能/文件/搜索/清理/备份；壁纸功能完整保留在功能页设备定制区。
- 清理页 UI 重构：汇总卡（总量/已选/累计已释放/快捷操作）、行可展开按目录勾选、受限目录锁标记、环形进度、吸顶摘要、两段确认。
- 功能页新增监管模式与应用存档备份入口；Gestalt 编辑页新增 预设库 / 字段编辑器 / 区域与 Siri AI 三个二级入口。
- 策略测试从 76 项扩展到 123 项（安全策略/身份快照/确认门/清理历史/活动时间线）。

## [3.1.13] - 2026-11-11

### Added

- 备份中心：首次触碰的原始文件快照、每次修改前的自动版本备份、手动备份、恢复与未完成事务恢复。
- 文件浏览器长按文件可创建手动备份；删除文件、替换文件、应用补丁前自动备份。
- 备份中心入口位于设置 → 备份与恢复；简中 / English / Tiếng Việt 三语界面。
- `VerifiedFileWriter`：原地写入，保留 inode/xattr，回读摘要校验，失败自动回滚。

### Changed

- 补丁应用与文件替换改用 `VerifiedFileWriter`，不再因原子写换掉 inode。
- 备份目录排除在系统备份与清理器之外，原始数据不可删除。
- App Data 与清理器改为 LaunchServices 数据库直出：首次找到库后持久化库路径与紧凑目录缓存，后续冷启动不再做 6–13 秒文件系统枚举。
- 列表先发布缓存目录，再后台补图标/版本；日志新增 `catalog cache load/built` 与首屏耗时。
- 数据库不可用时才回退文件系统扫描；MHA 候选激活在目录已完整时跳过。
- 主页替换为“功能”聚合页；底部固定 5 项：功能 / 文件 / 搜索 / 清理 / 壁纸。
- 仓库市场、仓库源、补丁工程与备份中心移入功能页；设置页移除底栏开关与开发者模式开关。
- 功能页、卡片说明与运行状态补齐简中 / English / Tiếng Việt 三语。
- 新增可取消扫描：进度、剩余时间、隐藏、停止、后台任务；回退枚举改用 `pathleak`。
- App Group 缺失时启动即提示签名要求；新增致谢与许可页、WebKit Respring。
- 新增 MobileGestalt 安全子集编辑器：设备名称/子类型、灵动岛、AOD、充电上限、开机提示音；原始缓存与每次写入前版本自动备份，可一键恢复。
- 新增拨号键主题：12 键图片替换、逐文件备份、恢复原始键图。
- 文件浏览器新增 SQLite 只读查看器、Hex 查看/覆写、结构化 Plist 编辑；写入统一走 `VerifiedFileWriter`。
- 利用层加固：补丁写入逐目标目录授权；worse_query 按设备学习并记住可用的 query flags。
- 文件浏览器新增文件信息页与左滑删除；清理器新增崩溃/诊断日志统计与清理。
- 支持矩阵补充 iOS 27.2.1 明示并加入策略测试（76 项）。

## [3.1.12] - 2026-11-10

### Fixed

- `.tendies` import no longer aborts the whole package with `unsafeArchive` when one extracted item fails the inspector's path/symlink check. The inspector now logs and skips that item, then continues; it also logs `inspecting package root` and `collected N descriptor sources`.
- Wallpaper layout discovery now logs `tree descriptor candidates=N` and, if the tree pass still returns nothing, runs a second path-suffix enumeration after the tree (`fallback descriptor candidates=N`). This no longer depends on `resourceValues` succeeding for the descriptors directory.

### Changed

- Includes 3.1.11's launch version banner and import stage logs.
- This is the stable release that rolls up 3.1.8–3.1.11: update-prompt fix, cleaner tab-switch caches, wallpaper ZIP compatibility, `/var` path handling, tree-based descriptor discovery, and import stage logs.
- Marketing version **3.1.12**; `CFBundleVersion` **16**.

## [3.1.11] - 2026-11-10

### Fixed

- Wallpaper layout discovery now collects `descriptors` directories from the same FileManager enumeration that produces the diagnostic tree. The earlier enumerator could return nothing depending on when the store directory was opened, even though the tree immediately afterwards listed every provider. The tree pass now returns the layout directly, so the probe sees all providers instead of falling back to a synthetic Collections-only layout.
- Import now logs `extracting`, `extracted`, and `inspected` stages, so an `unsafeArchive` can be attributed to the ZIP layer, the package inspector, or the final rename.
- The app logs its exact version and build at launch; a stale installed build is now visible in the first log line.
- Includes 3.1.10's `isContained` `/var` fix and 3.1.9's ZIP compatibility/caching fixes.

### Changed

- Marketing version **3.1.11**; `CFBundleVersion` **15** (test build, not published).

## [3.1.10] - 2026-11-10

### Fixed

- `.tendies` import no longer fails with `unsafeArchive` after extraction. `WallpaperLayoutScanner.isContained` compared raw `/var/...` and `/private/var/...` paths, so the extracted package root and its descriptor children looked like different trees; both paths are now canonicalized before the containment check.
- On-device wallpaper layout discovery now uses a FileManager enumerator first. A direct `fileExists`/`contentsOfDirectory` on `.../61/Extensions/...` is denied by the sandbox even though the enumerator can list it; the enumerator now finds all provider `descriptors` directories without the previous recursive depth heuristic.

### Changed

- Includes the 3.1.9 fixes: GB18030/backslash ZIP names, duplicate directory entries, 768 MB entry limit, `/private/var` scan root, LaunchServices/filesystem caches, and MHA scan skipping.
- Marketing version **3.1.10**; `CFBundleVersion` **14** (test build, not published).

## [3.1.9] - 2026-11-10

### Fixed

- Wallpaper scanning now explicitly forces the `/private/var` prefix. `resolvingSymlinksInPath()` alone left `/var` unchanged on iOS, so the scan still missed the existing `descriptors` directories.
- `.tendies` ZIP import accepts common Windows/Chinese archive quirks: GB18030 entry names when UTF-8 decoding fails, backslash path separators, and duplicate directory entries.
- The per-entry ZIP limit is now 768 MB instead of 256 MB, so dynamic/video wallpaper packages with a large video are no longer rejected as `unsafeArchive`.
- ZIP rejection diagnostics now log oversized entries, unsupported compression methods, encrypted entries, and duplicate file entries.

### Changed

- Switching from Cleaner to Files no longer re-parses the 18 MB LaunchServices store or repeats the 6-13 second filesystem scan. The LaunchServices snapshot, its identifier list, and the filesystem app list are reused for 10 seconds; an explicit refresh clears them.
- The MHA-C2 candidate scan is skipped when the LaunchServices snapshot has already identified at least 75% of the filesystem containers. It remains the fallback when LS parsing fails.
- Marketing version **3.1.9**; `CFBundleVersion` **13** (test build, not published).

## [3.1.8] - 2026-11-10

### Fixed

- The “update available” prompt no longer appears after installing the latest build. `Info.plist` still carried `AppReleaseDisplayVersion = 3.1.4`, which the update checker preferred over `CFBundleShortVersionString`; the stale field was removed and version metadata is now checked by the test script.
- Switching tabs while the cleaner is scanning no longer freezes the app. The cleaner published a full list update after every single app; publishing is now throttled to at most four updates per second, with a flush at the end of each batch.
- Wallpaper scanning now resolves `/var` and `/private/var` before enumerating, and recursive layout computes relative paths against either spelling. This fixes the case where the tree log listed `descriptors` directories but the scanner reported “no descriptor dirs”.
- `.tendies` packages that contain a `container` folder are no longer rejected when their temporary path uses a different `/var` spelling; the root validator now compares resolved directories.
- Wallpaper import failures now log the exact error key and message instead of only “import rejected”.

### Changed

- Marketing version **3.1.8**; `CFBundleVersion` **12**.

## [3.1.7] - 2026-11-10

### Fixed

- Wallpaper layout scanning no longer throws when the PosterBoard store has no numeric generation directory; it now falls through to the recursive search and the `61` generation fallback used by Erosion. This unblocks iOS 27.3 layouts where the old early `throw` made both fallbacks unreachable.
- Wallpaper generation selection now prefers the generation that already contains the provider extensions required by the package instead of always taking the highest numeric generation.
- Mercury wallpapers keep their original descriptor folder name (matching Erosion); other providers still use a fresh UUID directory.
- `.tendies` packages whose descriptor files live directly under `descriptors/` are accepted as one descriptor instead of being rejected with “no descriptors”.
- Descriptor folders containing `VideoCAML` are installed into the Photos provider instead of Collections.
- Added wallpaper layout and per-descriptor install diagnostics.
- Opening a favorited folder from the file tab page no longer shows an empty file list. A tab that starts directly at a subdirectory has no root browser beneath it, so it now grants the container root before the first listing instead of skipping the grant for non-root views.

### Changed

- Cleaner publishes after every app instead of only after an entire batch. Rows appear progressively, and a bottom row shows “Loaded N apps · M with removable data…” while the scan is running.
- Marketing version **3.1.7**; `CFBundleVersion` **11**.

## [3.1.6] - 2026-11-10

### Added

- Folder favorites: long-press a folder in the file browser and choose “Add to Favorites”. The JSON key and shape (`fileBrowserFavorites`, `id`/`path`/`name`) match 3105 2.0, so existing favorites survive the upgrade.
- Favorite paths are normalized (`/var` and `/private/var` are the same entry, trailing slashes ignored, duplicates removed).
- The file tab switcher (top-right) now has an inline Favorites section at the top, matching 3105 2.0’s actual layout: it lists each favorited folder’s name and full path directly, with swipe-to-remove, and tapping a row opens it in a new tab. There is no separate favorites screen and no Favorites entry in the Files home.
- Long-press favorite actions work in both normal and read-only file browsers (favoriting is local state, not a container write).

### Changed

- Marketing version **3.1.6**; `CFBundleVersion` **10**.

## [3.1.5] - 2026-11-10

### Fixed

- App Data browser no longer hides containers whose bundle identity cannot be resolved. The former `shouldShow` policy dropped every UUID-named container; they now appear in a separate “Unidentified containers” section, are browsable read-only, and are excluded from selection and write actions.
- Removed the hard-coded `com.apple.mobile.MobileHouseArrest` guard in `MCMActivateContainerPath`. After the 3106 rename to `com.qingtang.3106`, that guard made every MCM enumeration and lookup fail, which was the root cause of the missing app data.
- Added a LaunchServices `bdsl` CSStore parser (Swift port of WQ Files) that maps container paths to bundle ids directly, without MCM, the container identifier xattr, or the root-owned metadata plist. It reads lsd’s store from the Internal Daemon container and covers the 26 / 27.0 / 27.2 record layouts.
- Discovery now merges the LaunchServices store’s container list with the filesystem scan, and API/ MCM lookups fall back to the store path instead of dropping apps with an empty or bundle-only container.
- `installedAppInfo` now merges LaunchServices workspace and MobileInstallation results, and both enumeration selectors (`allApplications` / `allInstalledApplications`) and MobileInstallation option sets are unioned instead of “first non-empty wins”.
- The progress callback during the MHA candidate scan no longer replaces the list with identified-only entries, so the browser does not visibly shrink while scanning.
- Cleaner scans unidentified containers too and shows their `Library/Caches` + `tmp` usage, but marks them with a lock and disables selection/cleaning.

### Changed

- App Data browser rows for unidentified containers use a read-only file browser: import, new file/folder, paste, rename, delete, replacement, archive extraction, and patch creation are hidden.
- Marketing version **3.1.5**; `CFBundleVersion` **8**.

## [3.1.4-r2] - 2026-11-10

### Changed

- Project repository moved to `QuinnTang74/3106`; the in-app GitHub link, update checker API, README, and release links now point to the new address.
- App marketing version remains **3.1.4**; `CFBundleVersion` is now **7**.

## [3.1.4] - 2026-11-10

### Fixed

- Cleaner deletion uses the container path captured during the scan instead of re-resolving by bundle id; MCM being unavailable no longer turns selected apps into “bundle unavailable”.
- Cleaner removes `Library/Caches` and `tmp` contents through `FileManager` and only follows a symlinked Caches when its resolved target stays inside the app container.
- Added `cleaner: cleaning …`, `remove failed …`, and symlink-refusal diagnostics.

## [3.1.3] - 2026-11-10

### Fixed

- Wallpaper scanner accepts nested/non-standard PosterBoard stores by recursively locating `descriptors` directories.
- When no descriptor directory exists, the device scanner creates the required extension/descriptors path under the highest numeric generation, an existing `Extensions` directory, or the default `61/Extensions` layout.
- Synthetic layout creation is disabled for `.tendies` package scans, so package contents are never modified.
- Added a bounded PosterBoard store tree and recursive-descriptor diagnostic to the app log.

## [3.1.2] - 2026-11-10

### Fixed

- Cleaner measures `Library/Caches` and `tmp` with `FileManager` enumeration instead of `openat(O_NOFOLLOW)`, which rejected symlinked Caches directories and reported every app as empty.
- Cleaner prefers the container path already discovered by filesystem enumeration instead of re-resolving it through MCM.
- Cleaner shows the Settings gear at all times, including the empty/scan state.
- Wallpaper resolves PosterBoard by scanning app-data containers for `Library/Application Support/PRBPosterExtensionDataStore` when MCM and the bundle-id index both fail.
- Wallpaper view and service share the same fallback resolver; diagnostics now include the chosen container path.

## [3.1.1] - 2026-11-10

### Fixed

- Cleaner now enumerates app-data containers from the filesystem when MCM/LaunchServices return nothing (LiveContainer and similar signing environments).
- Cleaner resolves container paths through the iOS 27.2+ identifier index and no longer marks an app as scanned before its container was actually measured.
- Cleaner explicitly grants `Library/Caches` and `tmp` before measuring, matching WQ Files' grant-before-access pattern.
- Wallpaper layout scan, access probe, install, and reset now grant the PosterBoard container and descriptor directories before reading or creating probe files.
- Added a reverse container-index fallback plus `wallpaper:` / `cleaner:` diagnostics in the app log.

## [3.1.0] - 2026-11-10

### Added

- Settings now has tab bar toggles: up to five slots, Home always shown. Default slots are Home, New, Installed, Files, and Cleaner.
- Developer Mode is enabled by default.

### Changed

- Removed the social media and credits sections from Settings; the only link kept is the project repository.
- README is now Chinese-first with an English entry. Promotional content and the Vietnamese README were removed.
- `THIRD_PARTY_NOTICES.md` became `NOTICE.md`, containing only the attribution required by GPL-3.0.
- The license section now explains that the GPL-3.0 code cannot carry an additional non-commercial restriction, while retaining the author's commercial-use request and the mandatory attribution requirement.

### Compatibility

- iOS 27.3 beta 1 is exposed as an experimental `worse_query` target (device build 24C5037i).

## [3.0.0] - 2026-11-10

### Added

- `worse_query` sandbox backend for iOS 26.7–26.7.2 and iOS 27.0–27.2, ported from Taj C (forcequitOS) with the Caches-swap recovery, grant cache, and open verification adapted from WQ Files.
- Container identifier fallback through `container_query_iterate_results_sync` for iOS 27.2, where the identifier xattr and metadata plist are unreadable.
- App Group entitlement and a Settings row showing the active backend and App Group status.
- `.3106` patch extension for new exports; legacy `.3105` packages remain importable and decrypt with the unchanged `3105PATCH` format.

### Changed

- Project, target, scheme, product name, bundle identifier, URL scheme, localized strings, and documentation renamed from 3105 to 3106.
- Bundle identifier is now `com.qingtang.3106`; the MHA-C2 spoof was retired because it cannot carry an App Group for `worse_query`.
- iOS 26.0–26.6.1 keeps `bad_query`; iOS 26.7+ and 27.x automatically select `worse_query`.
- Signing guidance now targets AltStore/SideStore/Sideloadly with a free Apple ID, or an explicit App ID with App Groups.

### Fixed

- System Data/System Groups visibility follows the active backend (iOS 26 hides them; iOS 27 shows them).
- File browser, cleaner, patch transaction, and wallpaper installer now hold container grants for the whole operation.

### Compatibility

- Verified iOS 17.0–17.7.x and 18.0–18.7.1 (kernel exploit).
- Verified iOS 26.0–26.6.1 (`bad_query`) and 26.7–26.7.2 (`worse_query`).
- Verified iOS 27.0–27.2 (`worse_query`); 27.3 beta is experimental.

## [1.0.1] - 2026-08-15

### Added

- Bundle-tree Patch workspace v2 under `On My iPhone/3105/Patches`, synchronized automatically when applying or exporting.
- Multiple independent Files tabs with preserved navigation state.
- ZIP extraction with path, symbolic-link, CRC, and available-space validation.
- Responsive iPad split-view and landscape navigation.
- Home toggles for showing or hiding Cleaner and Wallpaper features.

### Changed

- Patch creation from an app-container file or folder now captures the stable bundle identifier and editable destination tree automatically.
- Patch package imports no longer use the previous fixed payload-size or file-count ceiling; practical device storage and memory still apply.
- Files and Patch screens now use consistent grouped cards, compact icons, balanced nested rows, and stable search presentation.
- Legacy v1 `.3105` packages remain importable and usable.

### Fixed

- Patch Restore now restores files that existed before Apply, removes files introduced by the patch, and removes patch-created folders after they become empty.
- File navigation remains at the current folder when switching app sections and restores the correct folder independently for each Files tab.
- Empty Patch and Cleaner actions now share the same visual treatment.
- Corrected PosterBoard wallpaper activation guidance and the iOS 27 Collections prerequisite.
- Refined navigation icon rendering and nested file-row spacing.

### Compatibility

- Verified iOS 26.0–26.6.1.
- Verified iOS 27 Developer Beta 1–4, including Public Beta 1–2 mappings listed in the app.
- Added iPhone and iPad interface support; device-level features still require enterprise signing.

## [1.0 beta 3] - 2026-08-14

### Added

- Bundle-based App Data Browser with MHA-C2 container discovery.
- Native file operations: search, multi-file import, rename, delete, create file/folder, and conflict handling.
- Portable `.3105` patch projects with optional password protection and file/folder rules.
- Limited per-app cleaner for `Library/Caches` and `tmp`.
- Wallpaper Lab for validated `.tendies` packages with installation receipts and targeted reset.
- English, Vietnamese, and Simplified Chinese localization.

### Changed

- Simplified the app into a five-tab, native SwiftUI layout inspired by focused iOS container tools.
- Moved the enterprise-signing notice below device information on Home.
- Refined the orange accent, empty states, actions, and navigation presentation.

### Fixed

- Stabilized persistent search presentation in app and file browsers.
- Fixed native document selection for replacement files and `.3105` package imports.
- Resolved bundle-name mapping for enumerated app containers where metadata is available.
- Limited wallpaper reset to active content installed by 3105.
- Corrected Cleaner layout when no removable app data is found.

### Compatibility

- Verified iOS 26.0–26.6.1.
- Verified iOS 27 beta 1–4 builds listed in the app.
- Unlisted iOS 27 builds remain disabled until explicitly verified.
