# 运行时验证脚本（macOS 宿主运行）

## filereplace 全流程（28 项）

```bash
cd /tmp && cp "$(pwd)/../Tests/verify_filereplace_main.swift.txt" /tmp/main.swift 2>/dev/null || true
# 从仓库根执行：
swiftc -O Tests/verify_filereplace_main.swift.txt \
  ThreeOneOSSix/helpers/FileReplaceService.swift \
  ThreeOneOSSix/helpers/ActivityHistory.swift \
  -o /tmp/filereplace-verify && /tmp/filereplace-verify
```
覆盖：替换+备份字节完整性、二次替换备份隔离、记录持久化、恢复+aside、
aside 清理上限、删除强制备份、删除后恢复（时序敏感）、受保护路径护栏 4 条、
预设增删改查去重持久化自清理。脚本自清理，不污染真实 ~/Documents。

## 更新检查端到端（7 项，打真 GitHub API）

```bash
swiftc -O Tests/verify_update_e2e.swift.txt -o /tmp/update-e2e && /tmp/update-e2e
```
覆盖：latest 可达、tag=v3.2.1、附件齐全、normalize 去 v、
3.2.1 设备不弹 / 3.2.0 与 3.1.13 设备弹（真实比较路径）。

## 结果（2026-11-12）
- FileReplace 全流程：PASS 28/28（双跑，自清理验证无残留）
- 更新检查 e2e：PASS 7/7
- CLI 策略链：PASS 146/146（含 23 项 v3.2.1 发布门断言）
- 二进制层：12 新模块符号/常量在最终 IPA 内确认；三语 .strings 新 key
  在 IPA 内确认（plutil -extract 的点号路径会误报，需转 XML 直查）
- 仅真机可验：红字横幅视觉、四要素体检的真机实时列、Siri AI 写入效果
