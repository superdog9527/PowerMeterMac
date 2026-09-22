import AppKit
import UniformTypeIdentifiers
import PowerMeterCore

final class SidebarDocument: NSView { override var isFlipped: Bool { true } }

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var window: NSWindow!
    private let status = NSTextField(labelWithString: "未连接")
    private let deviceLabel = NSTextField(labelWithString: "POWER Meter")
    private let voltageField = NSTextField(string: "3.300")
    private let outputSwitch = NSSwitch()
    private let captureButton = NSButton(title: "开始采集", target: nil, action: nil)
    private let connectButton = NSButton(title: "连接设备", target: nil, action: nil)
    private let voltageButton = NSButton(title: "设置并确认电压", target: nil, action: nil)
    private let voltageLimitLabel = NSTextField(labelWithString: "可设置 0.600–5.000 V · 步进 1 mV")
    private let ratePopup = NSPopUpButton()
    private let windowPopup = NSPopUpButton()
    private let liveSwitch = NSSwitch()
    private let scalePopup = NSPopUpButton()
    private let positionSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let rangeLabel = NSTextField(labelWithString: "0.000–10.000 s")
    private let chart = ChartView()
    private let markerALabel = NSTextField(labelWithString: "A：未设置")
    private let markerBLabel = NSTextField(labelWithString: "B：未设置")
    private let markerDeltaLabel = NSTextField(labelWithString: "B − A：—")
    private let markerHint = NSTextField(labelWithString: "选择 A / B 后点击波形，吸附采样点")
    private let currentLabel = NSTextField(labelWithString: "0.0 nA")
    private let averageLabel = NSTextField(labelWithString: "0.0 nA")
    private let minLabel = NSTextField(labelWithString: "0.0 nA")
    private let maxLabel = NSTextField(labelWithString: "0.0 nA")
    private let powerLabel = NSTextField(labelWithString: "0.000 µW")
    private var device: USBDevice?
    private var engine: CaptureEngine?
    private var displayTimer: Timer?
    private var displayDirty = false
    private var capturedMillivolts: Int?
    private var stats = MeasurementStatistics()
    private var voltageMillivolts: Int?
    private var outputEnabled = false
    private var capturing = false
    private var changingVoltage = false
    private var connecting = false
    private var automaticallyConnect = true
    private var connectionGeneration = 0
    private var connectionTimer: Timer?
    private let connectionQueue = DispatchQueue(label: "com.powermetermac.connect")
    private let controlQueue = DispatchQueue(label: "com.powermetermac.control", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Power Meter"; window.center(); window.contentMinSize = NSSize(width: 980, height: 640)
        buildUI(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "退出 Power Meter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        updateControls()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.displayDirty else { return }
            self.displayDirty = false; self.chart.refresh(); self.updateStats()
        }
        connect(automatic: true)
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.automaticallyConnect, self.device == nil, !self.connecting else { return }
            self.connect(automatic: true)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { displayTimer?.invalidate(); connectionTimer?.invalidate(); disconnect() }

    private func buildUI() {
        let root = NSView()
        window.contentView = root
        let sidebar = NSView(); sidebar.translatesAutoresizingMaskIntoConstraints = false
        let detail = NSView(); detail.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar); root.addSubview(detail)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 300),
            detail.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), detail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detail.topAnchor.constraint(equalTo: root.topAnchor), detail.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        sidebar.wantsLayer = true; sidebar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let cards = NSStackView(); cards.orientation = .vertical; cards.alignment = .leading; cards.spacing = 16
        cards.translatesAutoresizingMaskIntoConstraints = false; cards.detachesHiddenViews = false
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = SidebarDocument(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document; document.addSubview(cards); sidebar.addSubview(scroll)
        connectButton.target = self; connectButton.action = #selector(toggleConnect); connectButton.bezelStyle = .rounded
        deviceLabel.font = .systemFont(ofSize: 12, weight: .medium)
        cards.addArrangedSubview(section("设备", [deviceLabel, connectButton]))
        voltageField.placeholderString = "3.300"; voltageField.alignment = .right
        voltageField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let volts = row([voltageField, NSTextField(labelWithString: "V")])
        voltageLimitLabel.textColor = .secondaryLabelColor; voltageLimitLabel.font = .systemFont(ofSize: 11)
        voltageLimitLabel.maximumNumberOfLines = 2; voltageLimitLabel.lineBreakMode = .byWordWrapping
        voltageButton.target = self; voltageButton.action = #selector(applyVoltage)
        outputSwitch.target = self; outputSwitch.action = #selector(toggleOutput)
        cards.addArrangedSubview(section("电压输出", [volts, voltageLimitLabel, voltageButton, row([NSTextField(labelWithString: "电源输出"), outputSwitch])]))
        ratePopup.addItems(withTitles: SampleRate.allCases.map(\.label)); ratePopup.selectItem(withTitle: "100 kHz")
        liveSwitch.state = .on; liveSwitch.target = self; liveSwitch.action = #selector(toggleLive)
        captureButton.target = self; captureButton.action = #selector(toggleCapture)
        scalePopup.addItems(withTitles: AxisZoom.currents.map(formatScale))
        scalePopup.selectItem(at: AxisZoom.currents.firstIndex(of: 10_000_000) ?? 0); scalePopup.target = self; scalePopup.action = #selector(changeScale)
        cards.addArrangedSubview(section("采样", [row([NSTextField(labelWithString: "采样率"), ratePopup]), row([NSTextField(labelWithString: "电流上限"), scalePopup]), row([NSTextField(labelWithString: "实时视图"), liveSwitch]), captureButton]))
        for field in [markerALabel, markerBLabel, markerDeltaLabel, markerHint] {
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.maximumNumberOfLines = 2; field.lineBreakMode = .byWordWrapping
        }
        markerHint.textColor = .secondaryLabelColor
        chart.onMarkers = { [weak self] in self?.updateMarkers() }
        cards.addArrangedSubview(section("标记点", [row([
            NSButton(title: "设置 A", target: self, action: #selector(setMarkerA)),
            NSButton(title: "设置 B", target: self, action: #selector(setMarkerB)),
            NSButton(title: "清除标记", target: self, action: #selector(clearMarkers))
        ]), markerALabel, markerBLabel, markerDeltaLabel, markerHint]))
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11); status.maximumNumberOfLines = 3
        status.lineBreakMode = .byWordWrapping; status.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(status)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: sidebar.topAnchor), scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            cards.topAnchor.constraint(equalTo: document.topAnchor, constant: 20), cards.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            cards.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            status.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20), status.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -20),
            status.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -20), status.heightAnchor.constraint(equalToConstant: 48),
        ])
        let title = NSTextField(labelWithString: "电流波形"); title.font = .boldSystemFont(ofSize: 20)
        windowPopup.addItems(withTitles: AxisZoom.durations.map(formatDuration))
        windowPopup.selectItem(at: AxisZoom.durations.firstIndex(of: 10) ?? 0); windowPopup.target = self; windowPopup.action = #selector(changeWindow)
        let clear = NSButton(title: "清除", target: self, action: #selector(clearData)); let export = NSButton(title: "导出 CSV", target: self, action: #selector(exportCSV))
        let header = row([title, flexible(), windowPopup, clear, export])
        let metrics = statsView()
        positionSlider.target = self; positionSlider.action = #selector(moveHistory); positionSlider.isContinuous = true
        positionSlider.setAccessibilityLabel("历史时间位置")
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let navigation = row([rangeLabel, positionSlider, NSButton(title: "回到实时", target: self, action: #selector(followLatest))])
        positionSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chart.onNavigation = { [weak self] in self?.updateNavigation() }
        chart.onScale = { [weak self] in self?.updateScaleControls() }
        chart.setAccessibilityElement(true); chart.setAccessibilityRole(.image); chart.setAccessibilityLabel("电流波形")
        updateNavigation()
        chart.wantsLayer = true; chart.layer?.cornerRadius = 10
        for view in [header, chart, navigation, metrics] {
            view.translatesAutoresizingMaskIntoConstraints = false; detail.addSubview(view)
            view.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 22).isActive = true
            view.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -22).isActive = true
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: detail.topAnchor, constant: 20), header.heightAnchor.constraint(equalToConstant: 34),
            chart.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14), chart.bottomAnchor.constraint(equalTo: navigation.topAnchor, constant: -8),
            navigation.bottomAnchor.constraint(equalTo: metrics.topAnchor, constant: -14), navigation.heightAnchor.constraint(equalToConstant: 26),
            metrics.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -20), metrics.heightAnchor.constraint(equalToConstant: 54)
        ])
    }
    private func section(_ title: String, _ views: [NSView]) -> NSView {
        // NSBox does not derive its height from a replacement contentView.
        // Pin all four edges so the arranged controls determine the card's height.
        let card = NSView(); card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true; card.layer?.cornerRadius = 9
        card.layer?.borderWidth = 1; card.layer?.borderColor = NSColor.separatorColor.cgColor
        let heading = NSTextField(labelWithString: title); heading.font = .boldSystemFont(ofSize: 13)
        let stack = NSStackView(views: [heading] + views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.detachesHiddenViews = false; stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        for view in [heading] + views { view.setContentCompressionResistancePriority(.required, for: .vertical) }
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 260), stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        return card
    }
    private func row(_ views: [NSView]) -> NSStackView { let s = NSStackView(views: views); s.orientation = .horizontal; s.spacing = 8; return s }
    private func flexible() -> NSView { let v = NSView(); v.setContentHuggingPriority(.defaultLow, for: .horizontal); return v }
    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        return String(format: seconds.rounded() == seconds ? "%.0f s" : "%.3g s", seconds)
    }
    private func formatScale(_ nanoamps: Double) -> String {
        if nanoamps >= 1e9 { return String(format: "%.3g A", nanoamps / 1e9) }
        if nanoamps >= 1e6 { return String(format: "%.3g mA", nanoamps / 1e6) }
        if nanoamps >= 1e3 { return String(format: "%.3g µA", nanoamps / 1e3) }
        return String(format: "%.3g nA", nanoamps)
    }
    private func statsView() -> NSView {
        let labels = [("当前",currentLabel),("窗口平均",averageLabel),("最小",minLabel),("最大",maxLabel),("功耗",powerLabel)]
        let stack = NSStackView(); stack.orientation = .horizontal; stack.distribution = .fillEqually; stack.spacing = 10
        for (name, value) in labels { value.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold); let nameLabel = NSTextField(labelWithString: name); nameLabel.textColor = .secondaryLabelColor; nameLabel.font = .systemFont(ofSize: 11); let column = NSStackView(views: [nameLabel,value]); column.orientation = .vertical; column.alignment = .leading; stack.addArrangedSubview(column) }
        return stack
    }
    private var rate: SampleRate { SampleRate.allCases[ratePopup.indexOfSelectedItem] }
    @objc private func toggleConnect() {
        if device == nil { automaticallyConnect = true; connect(automatic: false) }
        else { disconnect() }
    }
    private func connect(automatic: Bool) {
        guard !connecting, device == nil else { return }
        connecting = true; connectionGeneration += 1
        let generation = connectionGeneration
        status.stringValue = "正在检测并连接 USB 设备…"; connectButton.title = "连接中…"; updateControls()
        connectionQueue.async { [weak self] in
            let result: Result<USBDevice?, Error>
            do {
                let devices = try USBDevice.discover()
                result = .success(devices.isEmpty ? nil : try USBDevice())
            } catch { result = .failure(error) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connectionGeneration == generation else {
                    if case .success(let device) = result { device?.close() }; return
                }
                self.connecting = false
                switch result {
                case .success(let device):
                    self.device = device
                    if let device {
                        self.engine = CaptureEngine(device: device)
                        self.deviceLabel.stringValue = "\(device.info.name) · \(device.info.serial)"
                        let maximum = min(SafetyPolicy.maximumMillivolts, device.info.maximumVolts * 1000)
                        self.voltageLimitLabel.stringValue = String(format: "可设置 0.600–%.3f V · 步进 1 mV", Double(maximum) / 1000)
                        self.connectButton.title = "断开连接"
                        self.status.stringValue = "已连接 · \(device.info.firmware)\n电源输出已关闭"
                    } else {
                        self.connectButton.title = "重新检测"
                        self.status.stringValue = "未发现设备，正在等待 USB 接入…"
                    }
                case .failure(let error):
                    self.connectButton.title = "重试连接"
                    self.status.stringValue = "连接失败：\(error.localizedDescription)"
                    if !automatic { self.show(error) }
                }
                self.updateControls()
            }
        }
    }
    private func updateControls() {
        let ready = device != nil && !connecting
        connectButton.isEnabled = !connecting && !changingVoltage
        voltageButton.isEnabled = ready && !changingVoltage
        voltageField.isEnabled = ready && !changingVoltage
        outputSwitch.isEnabled = ready && voltageMillivolts != nil && !capturing && !changingVoltage
        captureButton.isEnabled = ready && voltageMillivolts != nil && !changingVoltage
        ratePopup.isEnabled = !capturing
    }
    private func disconnect() {
        automaticallyConnect = false; connectionGeneration += 1; connecting = false
        controlQueue.sync {}
        engine?.stop()
        var shutdownError: Error?
        do { try device?.safeStop() } catch { shutdownError = error }
        device?.close(); device = nil; engine = nil; voltageMillivolts = nil; outputEnabled = false; capturing = false
        outputSwitch.state = .off; captureButton.title = "开始采集"; connectButton.title = "连接设备"
        deviceLabel.stringValue = "POWER Meter"
        voltageLimitLabel.stringValue = "可设置 0.600–5.000 V · 步进 1 mV"
        status.stringValue = shutdownError.map { "已断开，关闭输出未确认：\($0.localizedDescription)" } ?? "已断开连接"
        updateControls()
    }
    @objc private func applyVoltage() {
        do {
            guard let device, let engine else { throw MeterError.message("请先连接设备") }
            guard !changingVoltage else { return }
            let mv = try SafetyPolicy.millivolts(from: voltageField.stringValue)
            let changeDuringCapture = capturing
            changingVoltage = true
            status.stringValue = changeDuringCapture ? "正在建立采样边界并切换电压…" : "正在设置电压…"
            updateControls()
            controlQueue.async { [weak self] in
                let result = Result { if changeDuringCapture { try engine.changeVoltage(to: mv) } else { try device.setVoltage(mv) } }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.device === device else { return }
                    self.changingVoltage = false
                    switch result {
                    case .success:
                        self.voltageMillivolts = mv
                        self.voltageField.stringValue = String(format: "%.3f", Double(mv) / 1000)
                        self.status.stringValue = changeDuringCapture ? "采集中 · 设定电压已切换为 \(self.voltageField.stringValue) V" : "已确认电压 \(self.voltageField.stringValue) V"
                    case .failure(let error):
                        self.voltageMillivolts = device.millivolts
                        self.outputEnabled = device.outputEnabled
                        self.capturing = device.capturing
                        self.outputSwitch.state = self.outputEnabled ? .on : .off
                        self.captureButton.title = self.capturing ? "停止采集" : "开始采集"
                        self.show(error)
                    }
                    self.updateControls()
                }
            }
        } catch {
            voltageMillivolts = device?.millivolts; updateControls(); show(error)
        }
    }
    @objc private func toggleOutput() { do { guard let device else { throw MeterError.message("请先连接设备") }; let enable = outputSwitch.state == .on; try device.setOutput(enable); outputEnabled = enable; status.stringValue = enable ? "输出已开启 · \(voltageField.stringValue) V" : "输出已关闭" } catch { outputSwitch.state = outputEnabled ? .on : .off; show(error) } }
    @objc private func toggleCapture() {
        guard let engine else { show(MeterError.message("请先连接设备")); return }
        if capturing { engine.stop(); capturing = false; captureButton.title = "开始采集"; status.stringValue = "采集已停止"; updateControls(); return }
        do { let selected = rate; try engine.start(rate: selected, handler: { [weak self] batch, stats in DispatchQueue.main.async { self?.receive(batch, stats) } }, onError: { [weak self] error in DispatchQueue.main.async { guard let self else { return }; self.capturing = false; self.captureButton.title = "开始采集"; self.outputEnabled = self.device?.outputEnabled ?? false; self.outputSwitch.state = self.outputEnabled ? .on : .off; self.updateControls(); self.show(error) } }); chart.rate = selected; chart.reset(); stats = .init(); capturedMillivolts = voltageMillivolts; capturing = true; captureButton.title = "停止采集"; status.stringValue = "采集中 · \(selected.label)"; updateControls() } catch { outputEnabled = device?.outputEnabled ?? false; outputSwitch.state = outputEnabled ? .on : .off; updateControls(); show(error) }
    }
    private func receive(_ batch: [PowerMeterCore.Measurement], _ newStats: PowerMeterCore.MeasurementStatistics) { chart.history.append(batch); stats = newStats; displayDirty = true }
    @objc private func toggleLive() { chart.setLive(liveSwitch.state == .on) }
    @objc private func changeWindow() { chart.setDuration(AxisZoom.durations[windowPopup.indexOfSelectedItem]) }
    @objc private func changeScale() { chart.fullScaleNanoamps = Float(AxisZoom.currents[scalePopup.indexOfSelectedItem]) }
    @objc private func moveHistory() { chart.move(to: positionSlider.doubleValue) }
    @objc private func followLatest() { chart.setLive(true) }
    @objc private func setMarkerA() { chart.armMarker("A") }
    @objc private func setMarkerB() { chart.armMarker("B") }
    @objc private func clearMarkers() { chart.clearMarkers() }
    private func updateMarkers() {
        func text(_ name: String, _ sample: PowerMeterCore.Measurement?) -> String {
            guard let sample else { return "\(name)：未设置" }
            let time = EngineeringFormat.time(seconds: Double(sample.index) / Double(chart.rate.rawValue))
            let current = EngineeringFormat.current(nanoamps: Double(sample.nanoamps))
            return "\(name)  X \(time)\n    Y \(current)"
        }
        markerALabel.stringValue = text("A", chart.markerA); markerBLabel.stringValue = text("B", chart.markerB)
        if let a = chart.markerA, let b = chart.markerB {
            let deltaTime = EngineeringFormat.time(seconds: (Double(b.index) - Double(a.index)) / Double(chart.rate.rawValue), signed: true)
            let deltaCurrent = EngineeringFormat.current(nanoamps: Double(b.nanoamps) - Double(a.nanoamps), signed: true)
            markerDeltaLabel.stringValue = "B − A  ΔX \(deltaTime)\n       ΔY \(deltaCurrent)"
        } else { markerDeltaLabel.stringValue = "B − A：—" }
        markerHint.stringValue = chart.pendingMarker.map { "请点击波形设置 \($0)（已冻结视图）" } ?? "选择 A / B 后点击波形，吸附采样点"
    }
    private func updateNavigation() {
        liveSwitch.state = chart.live ? .on : .off
        if let index = AxisZoom.durations.firstIndex(where: { abs($0 - chart.viewport.duration) < 0.0000001 }) { windowPopup.selectItem(at: index) }
        positionSlider.minValue = chart.earliest; positionSlider.maxValue = max(chart.earliest + 0.000001, chart.maximumStart)
        positionSlider.doubleValue = chart.viewport.start; positionSlider.isEnabled = chart.maximumStart > chart.earliest
        let digits = max(3, Int(ceil(-log10(chart.viewport.duration / 10))))
        rangeLabel.stringValue = String(format: "%.*f–%.*f s", digits, chart.viewport.start, digits, chart.viewport.end)
        chart.setAccessibilityValue(rangeLabel.stringValue + (chart.live ? "，实时跟随" : "，历史视图"))
        averageLabel.stringValue = chart.windowAverage.map(formatCurrent) ?? "—"
    }
    private func updateScaleControls() {
        let value = Double(chart.fullScaleNanoamps)
        if let index = AxisZoom.currents.firstIndex(where: { abs($0 - value) < 0.1 }) { scalePopup.selectItem(at: index) }
    }
    @objc private func clearData() { chart.reset(); stats = .init(); updateStats() }
    @objc private func exportCSV() { guard chart.history.count > 0, let mv = capturedMillivolts else { show(MeterError.message("没有可导出的数据")); return }; let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "PowerMeter.csv"; if panel.runModal() == .OK, let url = panel.url { do { let samples = chart.history.measurements(); try CSVExporter.write(samples, rate: chart.rate, millivolts: mv, to: url); status.stringValue = "已导出 \(samples.count) 个样本" } catch { show(error) } } }
    private func updateStats() { currentLabel.stringValue = formatCurrent(stats.current); minLabel.stringValue = formatCurrent(stats.minimum); maxLabel.stringValue = formatCurrent(stats.maximum); let watts = voltageMillivolts.map { stats.powerWatts(millivolts: $0) } ?? 0; powerLabel.stringValue = watts >= 0.001 ? String(format: "%.3f mW",watts*1000) : String(format: "%.3f µW",watts*1_000_000) }
    private func formatCurrent(_ nA: Float) -> String { EngineeringFormat.current(nanoamps: Double(nA)) }
    private func show(_ error: Error) { status.stringValue = "错误：\(error.localizedDescription)"; let alert = NSAlert(); alert.messageText = "Power Meter"; alert.informativeText = error.localizedDescription; alert.runModal() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
