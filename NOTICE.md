# 版权与第三方声明

本文件用于满足 GPL-3.0 的版权、来源与许可声明要求，不是推广或致谢内容。

本项目包含或参考了以下第三方代码与技术：

- **3105**，作者 YangJiii，GPL-3.0。3106 基于 3105 2.0 源码修改。
- **worse_query**，作者 Taj C（forcequitOS），GPL-3.0-or-later。iOS 26.7+/27.x 的沙箱逃逸实现。
- **GestaltX**，作者 huamidev，GPL-3.0。MobileGestalt 预设键名与机型映射交叉核对来源。
- **YumEdit**，作者 H4CNPE，GPL-3.0。Siri AI 机型映射与区域修改护栏参考。
- **Erosion-CN**，作者 Kianuni，GPL-3.0。Erosion 简中加固版：防重启反弹规则、类型保真方法与出厂基线发现（Audio Intelligence 真机验证）。
- **WQManager**，作者 hseons，GPL-3.0。清理器安全策略与测量预算制设计参考。
- **WQ Files**，作者 kolbicz，GPL-3.0-or-later。LaunchServices 数据库直读、CSStore2 记录布局（含 iOS 26.5）与扫描诊断日志的参考实现。
- **AltGallery**，作者 bebound。软件源默认清单（AltStore 格式，61 个应用的聚合目录）。
- **WQ Files**，作者 Christoph Kolbicz，GPL-3.0-or-later。Caches 交换安全、授权缓存、容器标识回退等产品化实现参考；`ThreeOneOSSix/helpers/LaunchServicesStore.swift` 是 `WQLaunchServices.m` 中 LaunchServices `bdsl` CSStore 解析器的 Swift 移植（容器路径 ↔ bundle id、显示名、布局选择与边界检查）。
- **FilzaSlop**，作者 0xjohnnydev 及贡献者。MHA-C2 应用发现与沙盒逃逸基础。
- **Pocket Poster / Nugget**，作者 LeminLimez 及贡献者，GPL-3.0。`.tendies` 壁纸格式与相关实现基础。
- **Dopamine**，作者 opa334 及贡献者。iOS 17/18 内核利用基础。
- **CrazyMind90**。FilzaSlop 沙盒逃逸基础。

本项目的原始部分按 GPL-3.0 发布。上述第三方代码仍受其各自版权与许可证约束；本项目不重新许可这些代码。

二次修改或再分发时，必须保留本文件与 `LICENSE`，并注明修改内容。