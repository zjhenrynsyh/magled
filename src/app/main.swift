import AppKit
import Foundation
import ServiceManagement

// MagLED — menu bar app: one-click switch for the MagSafe 3 cable LED.
// All SMC writes go through the magled-helper root daemon (Unix socket).
// Reads are done directly (no root needed).

// 夜间时段改为可配置：以「当天 0 点起的分钟数」存在 UserDefaults 里
let kNightStartKey = "NightStartMinutes"
let kNightEndKey = "NightEndMinutes"
let kNightDefaultStart = 23 * 60   // 23:00
let kNightDefaultEnd = 7 * 60      // 07:00
let kNightPrefKey = "NightScheduleEnabled"
let kLastModeKey = "LastMode"

final class MagLEDController: NSObject, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var sMC: SMC.Client?

    // menu item references
    var statusItem2: NSMenuItem!
    var itemOff: NSMenuItem!
    var itemSystem: NSMenuItem!
    var itemGreen: NSMenuItem!
    var itemAmber: NSMenuItem!
    var itemNight: NSMenuItem!
    var itemNightWindow: NSMenuItem!
    var itemNightStart: NSMenuItem!
    var itemNightEnd: NSMenuItem!
    var itemLogin: NSMenuItem!
    var itemHelperStatus: NSMenuItem!
    var itemInstall: NSMenuItem!
    var itemFirmware: NSMenuItem!
    var itemAbout: NSMenuItem!

    var current: UInt8 = 0
    var supported = false
    var helperUp = false
    // SMC 访问串行队列：后台 refresh 与主线程写操作共用同一个 SMC.Client，需防并发
    let smcQueue = DispatchQueue(label: "com.atstudio.magled.smc")
    var nightEnabled = false {
        didSet { UserDefaults.standard.set(nightEnabled, forKey: kNightPrefKey) }
    }
    var nightApplied = false   // whether "night off" is currently in effect by the schedule
    var timer: Timer?
    var refreshWorkItem: DispatchWorkItem?

    func bootstrap() {
        let defaultItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = defaultItem
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        statusItem2 = NSMenuItem()
        let night = UserDefaults.standard.bool(forKey: kNightPrefKey)
        nightEnabled = night
        let saved = UserDefaults.standard.object(forKey: kLastModeKey) as? String
        // 白名单与 helper 的 kAllowed 对齐：0=系统 1=关 3=绿 4=橙 6=慢闪 7=快闪 0x19=闪后关
        if let s = saved, let v = UInt8(s, radix: 16), [0, 1, 3, 4, 6, 7, 0x19].contains(v) {
            current = v
        }

        let header = NSMenuItem(title: "MagSafe 灯", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        statusItem2.title = "…"
        statusItem2.isEnabled = false
        menu.addItem(statusItem2)
        menu.addItem(.separator())

        itemSystem = NSMenuItem(title: "跟随系统（默认）", action: #selector(setSystem), keyEquivalent: "")
        itemSystem.target = self
        menu.addItem(itemSystem)

        itemOff = NSMenuItem(title: "关闭灯光", action: #selector(setOff), keyEquivalent: "o")
        itemOff.target = self
        menu.addItem(itemOff)

        itemGreen = NSMenuItem(title: "常亮绿", action: #selector(setGreen), keyEquivalent: "")
        itemGreen.target = self
        menu.addItem(itemGreen)

        itemAmber = NSMenuItem(title: "常亮橙", action: #selector(setAmber), keyEquivalent: "")
        itemAmber.target = self
        menu.addItem(itemAmber)

        menu.addItem(.separator())
        itemNight = NSMenuItem(title: "夜间自动关灯（23:00–07:00）", action: #selector(toggleNight), keyEquivalent: "")
        itemNight.target = self
        menu.addItem(itemNight)

        // 夜间时段设置（子菜单：开始/结束时间 + 快捷预设）
        itemNightWindow = NSMenuItem(title: "夜间时段：23:00 – 07:00", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu()
        itemNightStart = NSMenuItem(title: "设置开始时间…", action: #selector(pickNightStart), keyEquivalent: "")
        itemNightStart.target = self
        windowMenu.addItem(itemNightStart)
        itemNightEnd = NSMenuItem(title: "设置结束时间…", action: #selector(pickNightEnd), keyEquivalent: "")
        itemNightEnd.target = self
        windowMenu.addItem(itemNightEnd)
        windowMenu.addItem(.separator())
        for (label, s, e) in [("22:00 – 08:00", 22 * 60, 8 * 60),
                              ("23:00 – 07:00（默认）", 23 * 60, 7 * 60),
                              ("00:00 – 06:00", 0, 6 * 60),
                              ("01:00 – 09:00", 60, 9 * 60)] {
            let preset = NSMenuItem(title: label, action: #selector(applyNightPreset(_:)), keyEquivalent: "")
            preset.target = self
            preset.representedObject = [s, e]
            windowMenu.addItem(preset)
        }
        itemNightWindow.submenu = windowMenu
        menu.addItem(itemNightWindow)

        itemLogin = NSMenuItem(title: "开机时启动", action: #selector(toggleLogin), keyEquivalent: "")
        itemLogin.target = self
        menu.addItem(itemLogin)

        menu.addItem(.separator())
        itemHelperStatus = NSMenuItem(title: "后台守护: …", action: nil, keyEquivalent: "")
        itemHelperStatus.isEnabled = false
        menu.addItem(itemHelperStatus)
        itemInstall = NSMenuItem(title: "安装后台守护（需要密码）", action: #selector(installHelper), keyEquivalent: "")
        itemInstall.target = self
        menu.addItem(itemInstall)

        itemFirmware = NSMenuItem(title: "固件: …", action: #selector(showFirmware), keyEquivalent: "")
        itemFirmware.target = self
        menu.addItem(itemFirmware)

        itemAbout = NSMenuItem(title: "关于 MagLED", action: #selector(showAbout), keyEquivalent: "")
        itemAbout.target = self
        menu.addItem(itemAbout)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MagLED", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        updateNightTitles()

        // wake/sleep re-assertion
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(handleWake), name: NSNotification.Name("com.apple.notice.powersaved"), object: nil)
        dnc.addObserver(self, selector: #selector(handleWake), name: NSNotification.Name("com.apple.coreservices.daemon.isTerminalDetected"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)

        updateLoginCheck()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            // 用 refresh 而非裸 tick：同时更新 helperUp/supported，
            // 避免唤醒后一次 ping 失败导致 helperUp 卡在 false、夜间计划彻底静默失效
            self?.refresh()
        }
        tick()
        refresh()

        // 固件信息（只读，IOKit 无需 root）——后台读一次
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let d = Fw.display()
            let kind = Fw.kind(d)
            let short = d?.short ?? "未检测到"
            DispatchQueue.main.async {
                self?.itemFirmware.title = "\(kind): \(short)"
            }
        }
    }

    // ---- state I/O ----

    func readCurrent() -> UInt8? {
        if helperUp, let r = LedSock.send("get"), r.ok, let v = UInt8(r.payload, radix: 16) {
            return v
        }
        return smcReadLED()
    }

    /// 直接读当前灯态（不走 helper；串行执行防并发；读取失败说明连接失效，丢弃下次重连）
    func smcReadLED() -> UInt8? {
        smcQueue.sync {
            if SMC.isLEDKeySupported() {
                if sMC == nil { sMC = try? SMC.Client() }
                if let c = sMC {
                    if let v = try? c.readByte(SMC.magSafeLEDKey) { return v }
                    // 读取失败：连接可能已失效（睡眠唤醒后常见）——丢弃，下次自动重连
                    sMC = nil
                }
            }
            return nil
        }
    }

    /// Mach-O 的代码/数据段内容（跳过头部页与 __LINKEDIT，排除代码签名差异）。
    /// 安装时重新 ad-hoc 签名会改变头部加载命令与尾部签名 blob，但机器码逐字节不变。
    private static func machCodeBody(_ data: Data) -> Data? {
        guard data.count >= 32 else { return nil }
        let magic = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard magic == 0xfeedfacf else { return nil }   // MH_MAGIC_64
        let ncmds = data.subdata(in: 16..<20).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        var off = 32, headerEnd = 32, linkeditStart = data.count
        for _ in 0..<ncmds {
            guard off + 8 <= data.count else { return nil }
            let cmd = data.subdata(in: off..<off+4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let cmdsize = data.subdata(in: off+4..<off+8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            guard cmdsize >= 8, off + Int(cmdsize) <= data.count else { return nil }
            if cmd == 0x19 {  // LC_SEGMENT_64
                let name = String(decoding: data.subdata(in: off+8..<off+24).prefix(while: { $0 != 0 }), as: UTF8.self)
                if name == "__LINKEDIT" {
                    let fileoff = data.subdata(in: off+40..<off+48).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                    linkeditStart = min(linkeditStart, Int(fileoff))
                }
            }
            off += Int(cmdsize)
            headerEnd = off
        }
        let start = max(headerEnd, 4096)   // 头部页含随签名变化的 LC_CODE_SIGNATURE，不参与比较
        guard start < linkeditStart else { return nil }
        return data.subdata(in: start..<linkeditStart)
    }

    /// 已安装的守护是否比 App 自带版本旧（需要更新才会提示）
    var daemonOutdated: Bool {
        let installed = "/usr/local/lib/magled/magled-helper"
        guard let res = Bundle.main.resourcePath else { return false }
        let bundled = (res as NSString).appendingPathComponent("magled-helper")
        guard let a = try? Data(contentsOf: URL(fileURLWithPath: installed)),
              let b = try? Data(contentsOf: URL(fileURLWithPath: bundled)) else { return false }
        guard let ba = Self.machCodeBody(a), let bb = Self.machCodeBody(b) else { return a != b }
        return ba != bb
    }

    func writeCurrent(_ v: UInt8) -> Bool {
        guard helperUp else { return false }
        let hex = String(format: "%02x", v)
        if let r = LedSock.send("set \(hex)"), r.ok { return true }
        // 旧版 helper 的回读校验有 bug（readByte 未设置 dataSize，macOS 27 上读到 0xff 桩值），
        // 会误报 "ERR write-failed"——但写入本身是有效的。此时直接读回验证：
        // 值已生效即视为成功。
        Thread.sleep(forTimeInterval: 0.15)
        guard let back = smcReadLED() else { return false }
        if v == 0 {
            // 系统模式（0x00）回读的是"当前生效颜色"（如满电绿=0x03），不可能等于 0：
            // 读到任何合法值即视为生效。
            return [0, 1, 3, 4, 6, 7, 0x19, 0xff].contains(back)
        }
        return back == v
    }

    func refresh() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // I/O 全部放后台线程：socket ping/read 最长 5 秒超时，不能阻塞主线程（菜单栏 UI）
            let up = LedSock.helperRunning()
            // ACLC 键存在性不会在运行时段变化：一旦检测到支持就锁存，避免瞬时读取抖动误报"不支持"；
            // 尚未确认支持时最多重试 3 次。
            var sup = self.supported
            if !sup {
                for _ in 0..<3 {
                    if sup { break }
                    sup = SMC.isLEDKeySupported()
                }
            }
            let v = self.readCurrent()
            DispatchQueue.main.async {
                self.helperUp = up
                self.supported = sup
                if let v = v {
                    // macOS 27 上系统模式（0x00）回读为"当前生效颜色"（如满电=0x03）：
                    // 用户选"跟随系统"时不要被回读覆盖，否则勾选会跳到颜色项上。
                    if !(self.current == 0 && v != 0) { self.current = v }
                }
                self.rebuildMenu()
                if self.nightEnabled { self.tick() }
            }
        }
        refreshWorkItem?.cancel()
        refreshWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func rebuildMenu() {
        var titles: [String]
        if !supported {
            titles = ["这台 Mac 没有 MagSafe 3，无灯可关"]
            itemSystem.title = "跟随系统（默认）"
            itemOff.title = "关闭灯光（不可用）"
            itemGreen.title = "常亮绿（不可用）"
            itemAmber.title = "常亮橙（不可用）"
            itemSystem.isEnabled = false
            itemOff.isEnabled = false
            itemGreen.isEnabled = false
            itemAmber.isEnabled = false
        } else {
            itemSystem.isEnabled = true
            itemOff.isEnabled = true
            itemGreen.isEnabled = true
            itemAmber.isEnabled = true
            titles = [
                "当前: \(LEDModeText.current(current))",
                "跟随系统（默认）",
                "关闭灯光",
                "常亮绿",
                "常亮橙"
            ]
            itemSystem.title = titles[1]
            itemOff.title = titles[2]
            itemGreen.title = titles[3]
            itemAmber.title = titles[4]
            if helperUp {
                statusItem2.title = "当前: \(LEDModeText.current(current))"
            } else {
                statusItem2.title = "当前: \(LEDModeText.current(current))（守护离线，重启后不保持）"
            }
        }

        let states: [(NSMenuItem, UInt8)] = [(itemSystem, 0), (itemOff, 1), (itemGreen, 3), (itemAmber, 4)]
        for (item, v) in states where supported {
            item.state = (current == v) ? .on : .off
        }
        itemNight.state = nightEnabled ? .on : .off
        updateNightTitles()
        itemHelperStatus.title = helperUp ? "后台守护: 运行中 ✓" : "后台守护: 未安装"
        // 守护在跑但二进制旧了 → 显示"更新"入口（点一次输一次密码，之后不再问）；
        // 未安装 → 显示"安装"；已是最新 → 隐藏。
        if daemonOutdated {
            itemInstall.title = "更新后台守护（需要密码）"
            itemInstall.isHidden = false
        } else {
            itemInstall.title = "安装后台守护（需要密码）"
            itemInstall.isHidden = helperUp
        }
        updateIcon()
    }

    func updateIcon() {
        let off = !supported || current == 1
        let symbol = off ? "lightbulb.slash" : "lightbulb.fill"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "MagSafe LED")
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    // ---- actions ----

    @objc func setSystem() { applyMode(0, title: "跟随系统") }
    @objc func setOff() { applyMode(1, title: "已关闭") }
    @objc func setGreen() { applyMode(3, title: "常亮绿") }
    @objc func setAmber() { applyMode(4, title: "常亮橙") }

    func applyMode(_ v: UInt8, title: String) {
        guard supported else { flash(title: "这台 Mac 没有 MagSafe 3 硬件") ; return }
        guard helperUp else {
            flash(title: "后台守护未安装 — 点下方「安装后台守护」安装（仅需一次密码，之后不再询问）")
            return
        }
        current = v
        UserDefaults.standard.set(String(format: "%02x", v), forKey: kLastModeKey)
        nightApplied = false
        let ok = writeCurrent(v)
        flash(title: ok ? "已\(title)" : "设置失败 — 守护异常？")
        rebuildMenu()
        refresh()
    }

    func flash(title: String) {
        statusItem2.title = title
        statusItem2.isEnabled = false
        let work = DispatchWorkItem { [weak self] in self?.rebuildMenu() }
        refreshWorkItem?.cancel()
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    @objc func toggleNight() {
        nightEnabled.toggle()
        itemNight.state = nightEnabled ? .on : .off
        if nightEnabled { tick() } else {
            // restore to system when disabling
            if helperUp { _ = writeCurrent(0); current = 0 }
            nightApplied = false
            rebuildMenu()
        }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            flash(title: "开机自启设置失败: \(error.localizedDescription)")
        }
        updateLoginCheck()
    }

    func updateLoginCheck() {
        itemLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func installHelper() {
        let resources = Bundle.main.resourcePath ?? ""
        let script = (resources as NSString).appendingPathComponent("install.sh")
        guard FileManager.default.fileExists(atPath: script) else {
            flash(title: "找不到 install.sh（应用包不完整？）")
            return
        }
        let esc = script.replacingOccurrences(of: "\"", with: "\"\"")
        let appleScript = "do shell script \"sh \(esc)\" with prompt \"安装 magled 后台守护\" with administrator privileges"
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", appleScript]
        task.terminationHandler = { [weak self] t in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refresh()
                self.flash(title: t.terminationStatus == 0 ? "后台守护已安装 ✓" : "安装被取消或失败")
            }
        }
        do { try task.run() } catch { flash(title: "无法启动安装: \(error.localizedDescription)") }
    }

    @objc func showFirmware() {
        itemFirmware.title = "固件: 读取中…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let d = Fw.display()
            let kind = Fw.kind(d)
            var detail: String
            if let d = d {
                detail = d.text
                if d.channel == "AppleHPM" {
                    detail += "\n\n说明: “FW Version”（ioreg 原始字节）= 电源口控制器固件，同机各口同值。"
                    detail += "社区对照: <00633000> = MagSafe 3 线缆固件旧版 3.1.12；"
                    detail += "出现其他值 = 苹果已推送线缆固件更新（3.2.0 或更新）。"
                } else if d.channel == "CableFW" {
                    detail += "\n\n说明: 系统 hpmdiagnose 0x49 行的线缆 USB 控制器 bcdDevice。"
                } else {
                    detail += "\n\n说明: SMC/IOKit 兜底渠道（原始值，未经厂商文档确认）。"
                }
            } else {
                detail = "未找到固件版本信息。\n\n本机（\(Fw.hostMachine())）的电源口未暴露 FW Version 属性。"
            }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "MagSafe 3 固件信息"
                alert.informativeText = detail
                alert.addButton(withTitle: "好")
                alert.runModal()
                self?.itemFirmware.title = "\(kind): " + (d?.short ?? "未检测到")
            }
        }
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "MagLED 1.1"
        alert.informativeText = """
        MagSafe 3 充电线 LED 开关。

        原理: Mac 的 SMC 系统管理控制器（ACLC 密钥）控制线缆指示灯。
        - 00 系统 / 01 关闭 / 03 常亮绿 / 04 常亮橙
        - 写入 SMC 需要 root，因此配合一个小型后台守护（magled-helper）。
        - 守护会在重启、拔插、睡眠唤醒后自动保持你选的灯态。

        灯是纯装饰，关掉不影响充电、电池和任何功能。
        仅供技术研究，非 Apple 官方工具。
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc func quit() { NSApplication.shared.terminate(nil) }

    @objc func handleWake() {
        // SMC can reset on wake; re-assert current mode if the helper is up
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.helperUp, self.supported else { return }
            if self.nightEnabled && !inNight() { self.nightApplied = false }
            if self.current != 0 {
                _ = self.writeCurrent(self.current)
            }
        }
        self.refresh()
    }

    // ---- night schedule ----

    // 时段存取：0 点起的分钟数
    var nightStartMinutes: Int {
        get { UserDefaults.standard.object(forKey: kNightStartKey) as? Int ?? kNightDefaultStart }
        set { UserDefaults.standard.set(newValue, forKey: kNightStartKey); updateNightTitles() }
    }
    var nightEndMinutes: Int {
        get { UserDefaults.standard.object(forKey: kNightEndKey) as? Int ?? kNightDefaultEnd }
        set { UserDefaults.standard.set(newValue, forKey: kNightEndKey); updateNightTitles() }
    }

    func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    static func parseHHMM(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    func updateNightTitles() {
        let window = "\(hhmm(nightStartMinutes)) – \(hhmm(nightEndMinutes))"
        itemNight?.title = "夜间自动关灯（\(window)）"
        itemNightWindow?.title = "夜间时段：\(window)"
        itemNightStart?.title = "设置开始时间…（现在 \(hhmm(nightStartMinutes))）"
        itemNightEnd?.title = "设置结束时间…（现在 \(hhmm(nightEndMinutes))）"
    }

    @objc func pickNightStart() { promptNightTime(isStart: true) }
    @objc func pickNightEnd() { promptNightTime(isStart: false) }

    @objc func applyNightPreset(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Int], pair.count == 2 else { return }
        nightStartMinutes = pair[0]
        nightEndMinutes = pair[1]
        evaluateNight(force: true)
    }

    func promptNightTime(isStart: Bool) {
        let alert = NSAlert()
        alert.messageText = isStart ? "夜间关灯开始时间" : "夜间恢复时间"
        alert.informativeText = "24 小时制，格式 HH:MM，例如 22:30 或 06:45"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = hhmm(isStart ? nightStartMinutes : nightEndMinutes)
        field.alignment = .center
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return }
        guard let minutes = Self.parseHHMM(field.stringValue) else {
            flash(title: "时间格式不对，请用 HH:MM（例如 22:30）")
            return
        }
        if isStart { nightStartMinutes = minutes } else { nightEndMinutes = minutes }
        evaluateNight(force: true)
    }

    /// 立即按新的时间窗判断一次（改完时间不用等下一个 30 秒 tick）
    func evaluateNight(force: Bool) {
        guard nightEnabled else { flash(title: "时段已保存（夜间计划未开启）"); return }
        let shouldOff = inNight()
        nightApplied = !shouldOff
        tick()
        flash(title: shouldOff ? "已按新时段关灯" : "当前不在关灯时段")
    }

    func inNight() -> Bool {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let s = nightStartMinutes, e = nightEndMinutes
        if s == e { return false }                    // 起止相同 = 不启用
        return s < e ? (now >= s && now < e)          // 同一天内的窗口
                     : (now >= s || now < e)          // 跨零点
    }

    func tick() {
        guard nightEnabled, supported, helperUp else { return }
        let shouldOff = inNight()
        if shouldOff != nightApplied {
            // 状态切换：进入夜间 → 关灯；离开夜间 → 交还系统
            nightApplied = shouldOff
            let v: UInt8 = shouldOff ? 1 : 0
            if writeCurrent(v) {
                current = v
                rebuildMenu()
                flash(title: shouldOff ? "夜间模式：灯已关闭" : "夜间结束：恢复系统")
            }
        } else if shouldOff, let v = readCurrent(), v != 1 {
            // 夜间防抖：固体会在睡眠唤醒/拔插充电线后把灯重置回系统色——
            // 每 30 秒核对一次，发现漂移立即重新关灯（不依赖 helper 看门狗）
            if writeCurrent(1) {
                current = 1
                rebuildMenu()
                flash(title: "夜间模式：灯被系统重置，已重新关闭")
            }
        }
    }
}

final class App: NSObject, NSApplicationDelegate {
    var controller: MagLEDController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let c = MagLEDController()
        c.bootstrap()
        controller = c
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
