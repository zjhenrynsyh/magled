# CHANGELOG

本文件记录相对上游 [shaoya828/magled](https://github.com/shaoya828/magled) 的全部变更。
技术细节与踩坑结论见 [AI-CONTEXT.md](AI-CONTEXT.md)。

## v1.2.1 (2026-10-27)

### 🟢 新功能：夜间时段可在菜单栏自定义

- **夜间计划不再写死 23:00–07:00**：菜单栏新增「夜间时段」子菜单，可直接设置开始/结束时间，
  支持任意时分（`HH:MM`），另有 4 个快捷预设；设置即时生效，无需重启。
- 时间改为存在 `UserDefaults`（`NightStartMinutes` / `NightEndMinutes`，单位：0 点起的分钟数），
  默认值仍为 23:00–07:00，保持向后兼容。
- **窗口判断重写**：原实现只支持跨零点（`h >= 23 || h < 7`），现在同一天内的窗口（如 13:00–15:00）
  也正确处理；起止时间相同视为不启用。
- 菜单标题实时显示当前时段（如「夜间自动关灯（22:00 – 09:00）」），一眼可见当前设置。

## v1.2 (2026-10-26)

### 🔴 关键修复（macOS 27 兼容化）

- **SMC.swift `readByte`**：补 `keyInfo.dataSize=1`——macOS 27 上原实现读到 0xff 桩值/抛错，
  导致回读校验全面误判「写入失败」（写入其实一直有效），这是「工具看似失效」的根因。
- **helper `apply()`**：适配 macOS 27 新语义——ACLC 系统模式（0x00）回读返回**当前生效颜色**
  （满电=0x03）而非 0x00，回读校验改为「v=0 时合法值即通过」。
- **app `tick()` 夜间防漂移**：每 30 秒核对灯态，固件在睡眠唤醒后重置灯态时自动恢复（实测 11 秒抓回）。
- **app 定时器改调 `refresh()`**：唤醒后一次 ping 失败不再导致 `helperUp` 卡死、夜间计划静默失效。
- **app `daemonOutdated`**：守护版本检测改 Mach-O 机器码对比（跳过头部页与 __LINKEDIT），
  不受安装时重签名影响，不再误报「需要更新」。
- **install.sh**：先停旧守护再拷贝（修复覆盖运行中二进制的竞态）；幂等（二进制没变不重装不弹密码）。
- **uninstall.sh**：卸载前经 socket 发 `set 00`，兑现「卸载后 LED 交还系统控制」。

### 🟡 稳定性与体验

- helper 主循环 `usleep(1s)`→50ms（原来每请求排队 1 秒）；`handleOne` 加 5 秒读超时（防挂死）。
- helper/App 的 SMC 客户端读失败即丢弃重连（防睡眠唤醒后陈旧连接永久失效）。
- App 的 socket/SMC I/O 移出主线程（后台队列 + SMC 串行队列），UI 不再可能被 5 秒超时卡住。
- App 不再在守护未安装时自动弹安装密码框；重启恢复白名单补全闪烁模式。
- helper `set` 先写成功再持久化（防状态文件与实际灯态不一致）。
- App `writeCurrent` 加读回验证兜底（兼容旧版守护的误报）。

### 🟢 文档与清理

- probe 删掉写死的「Mac Studio」误导注释，改动态机器信息 + 值图例。
- Sock.swift connect addrlen 与 bind 统一；Fw.swift 修 CFDictionary 泄漏与格式化。
- 新增 `AI-CONTEXT.md`（AI 任务记忆）；README 加 fork 说明并修正协议表。

## v1.1 (2026-10，上游)

- shaoya828/magled 的原始版本（菜单栏 App + root 守护 + CLI）。
