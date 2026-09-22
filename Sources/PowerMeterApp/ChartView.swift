import AppKit
import PowerMeterCore

final class ChartView: NSView {
    let history = SampleHistory()
    var rate: SampleRate = .k100
    var fullScaleNanoamps: Float = 10_000_000 { didSet { needsDisplay = true; onScale?() } }
    var onScale: (() -> Void)?
    private var scrollAxis: ChartAxis?
    private var scrollRemainder: CGFloat = 0
    private(set) var viewport = TimeViewport()
    private var frozen: SampleHistory?
    private var dragOrigin: (x: CGFloat, start: Double)?
    var onNavigation: (() -> Void)?
    var onMarkers: (() -> Void)?
    private(set) var markerA: PowerMeterCore.Measurement?
    private(set) var markerB: PowerMeterCore.Measurement?
    private(set) var pendingMarker: String?
    var visibleRange: Range<UInt64> { source.visibleRange(start: viewport.start, end: viewport.end, rate: Double(rate.rawValue)) }
    var windowAverage: Float? { source.average(in: visibleRange) }
    func armMarker(_ name: String) {
        setLive(false); pendingMarker = name; window?.invalidateCursorRects(for: self); onMarkers?()
    }
    func clearMarkers() { markerA = nil; markerB = nil; pendingMarker = nil; needsDisplay = true; onMarkers?() }
    var live: Bool { viewport.followsLatest }
    private var source: SampleHistory { frozen ?? history }
    var earliest: Double { Double(source.startIndex) / Double(rate.rawValue) }
    var latest: Double { Double(source.endIndex) / Double(rate.rawValue) }
    var maximumStart: Double { max(earliest, latest - viewport.duration) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var plot: NSRect {
        NSRect(x: 78, y: 45, width: max(1, bounds.width - 102), height: max(1, bounds.height - 108))
    }
    func setLive(_ value: Bool) {
        if value { frozen = nil; pendingMarker = nil; viewport.follow(earliest: earliest, latest: latest); onMarkers?() }
        else { if frozen == nil { frozen = history.snapshot() }; viewport.move(to: viewport.start, earliest: earliest, latest: latest) }
        needsDisplay = true; onNavigation?()
    }
    func setDuration(_ seconds: Double) {
        viewport.setDuration(seconds, earliest: earliest, latest: latest)
        needsDisplay = true; onNavigation?()
    }
    func refresh() {
        if live { viewport.update(earliest: earliest, latest: latest); needsDisplay = true; onNavigation?() }
    }
    func reset() {
        clearMarkers()
        history.reset(); frozen = nil; viewport.follow(earliest: 0, latest: 0)
        needsDisplay = true; onNavigation?()
    }
    func move(to seconds: Double) {
        if live { setLive(false) }
        viewport.move(to: seconds, earliest: earliest, latest: latest)
        needsDisplay = true; onNavigation?()
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard plot.contains(point) else { return }
        window?.makeFirstResponder(self); setLive(false)
        if let name = pendingMarker {
            let time = viewport.start + Double((point.x - plot.minX) / plot.width) * viewport.duration
            if let sample = source.nearest(to: time, rate: Double(rate.rawValue), in: visibleRange) {
                if name == "A" { markerA = sample } else { markerB = sample }
                pendingMarker = nil; needsDisplay = true; onMarkers?(); window?.invalidateCursorRects(for: self)
            }
            return
        }
        dragOrigin = (point.x, viewport.start)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let x = convert(event.locationInWindow, from: nil).x
        move(to: origin.start - Double((x - origin.x) / plot.width) * viewport.duration)
    }
    override func mouseUp(with event: NSEvent) { dragOrigin = nil }
    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let axis = AxisZoom.target(x: point.x, y: point.y,
                                         plotMinX: plot.minX, plotMaxX: plot.maxX,
                                         plotMinY: plot.minY, plotMaxY: plot.maxY,
                                         width: bounds.width, height: bounds.height) else {
            scrollAxis = nil; scrollRemainder = 0; return
        }
        // Ignore trackpad momentum: zoom only while the user actively scrolls an axis.
        guard event.momentumPhase.isEmpty else { return }
        if scrollAxis != axis || event.phase == .began { scrollRemainder = 0 }
        scrollAxis = axis
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if scrollRemainder * delta < 0 { scrollRemainder = 0 }
        scrollRemainder += delta
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 24 : 1
        guard abs(scrollRemainder) >= threshold else { return }
        let inward = scrollRemainder > 0
        scrollRemainder = 0
        if axis == .x {
            let duration = AxisZoom.next(viewport.duration, inward: inward, levels: AxisZoom.durations)
            guard duration != viewport.duration else { return }
            setLive(false)
            viewport.zoom(to: duration, anchorFraction: Double((point.x - plot.minX) / plot.width), earliest: earliest, latest: latest)
            needsDisplay = true; onNavigation?()
        } else {
            fullScaleNanoamps = Float(AxisZoom.next(Double(fullScaleNanoamps), inward: inward, levels: AxisZoom.currents))
        }
    }
    override func magnify(with event: NSEvent) {} // The time window never responds to pinch zoom.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: move(to: viewport.start - viewport.duration / 10)
        case 124: move(to: viewport.start + viewport.duration / 10)
        case 115: move(to: earliest)
        case 119: setLive(true)
        default: super.keyDown(with: event)
        }
    }
    override func resetCursorRects() {
        addCursorRect(plot, cursor: pendingMarker == nil ? .openHand : .crosshair)
        addCursorRect(NSRect(x: plot.minX, y: plot.maxY, width: plot.width, height: bounds.maxY - plot.maxY), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: plot.minY, width: plot.minX, height: plot.height), cursor: .resizeUpDown)
    }
    private func label(_ text: String, at point: NSPoint, color: NSColor = .secondaryLabelColor, right: Bool = false, center: Bool = false) {
        let s = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color])
        var p = point
        if right { p.x -= s.size().width }; if center { p.x -= s.size().width / 2 }
        s.draw(at: p)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        let area = plot
        let divisor: Float = fullScaleNanoamps >= 1e9 ? 1e9 : fullScaleNanoamps >= 1e6 ? 1e6 : fullScaleNanoamps >= 1e3 ? 1e3 : 1
        let unit = divisor == 1e9 ? "A" : divisor == 1e6 ? "mA" : divisor == 1e3 ? "µA" : "nA"
        label("电流 (\(unit))", at: NSPoint(x: 12, y: 14))
        label(String(format: "窗口 %.3g s · %@", viewport.duration, live ? "实时跟随" : "历史视图"), at: NSPoint(x: bounds.width - 18, y: 14), right: true)
        let grid = NSBezierPath(); grid.lineWidth = 0.5
        for i in 0...5 {
            let y = area.maxY - Double(i) / 5 * area.height
            grid.move(to: NSPoint(x: area.minX, y: y)); grid.line(to: NSPoint(x: area.maxX, y: y))
            label(String(format: "%.3g", Double(fullScaleNanoamps / divisor) * Double(i) / 5), at: NSPoint(x: area.minX - 10, y: y - 7), right: true)
        }
        let rawTick = viewport.duration / max(2, floor(area.width / 80))
        let magnitude = pow(10, floor(log10(rawTick)))
        let tick = ([1.0, 2, 5, 10].first { $0 * magnitude >= rawTick } ?? 10) * magnitude
        let firstTick = ceil((viewport.start - tick * 1e-8) / tick) * tick
        let tickCount = max(1, Int(ceil(viewport.duration / tick)) + 1)
        for i in 0...tickCount {
            let time = firstTick + Double(i) * tick
            let fraction = viewport.fraction(at: time)
            guard fraction >= -1e-8, fraction <= 1 + 1e-8 else { continue }
            let x = area.minX + fraction * area.width
            grid.move(to: NSPoint(x: x, y: area.minY)); grid.line(to: NSPoint(x: x, y: area.maxY))
            let text = String(format: "%.*f", max(0, Int(ceil(-log10(tick)))), time)
            label(text, at: NSPoint(x: x, y: area.maxY + 9), center: true)
        }
        NSColor.separatorColor.setStroke(); grid.stroke()
        let border = NSBezierPath(rect: area); border.lineWidth = 1; border.stroke()
        label("时间 (s) · 按样本序号计算", at: NSPoint(x: area.minX, y: area.maxY + 33))
        label("轴上滚动缩放 · 图内拖动平移", at: NSPoint(x: area.maxX, y: area.maxY + 33), right: true)
        guard source.count > 0 else {
            label("等待采样，时间轴保持固定长度", at: NSPoint(x: area.minX + 16, y: area.minY + 16)); return
        }
        let hz = Double(rate.rawValue)
        var points = source.polyline(in: visibleRange, columns: max(1, Int(area.width)))
        // Always retain selected real samples as polyline vertices, even in dense views.
        for sample in [markerA, markerB].compactMap({ $0 }) where visibleRange.contains(sample.index) {
            if !points.contains(where: { $0.index == sample.index }) { points.append(sample) }
        }
        points.sort { $0.index < $1.index }
        let line = NSBezierPath(); line.lineWidth = 1
        var clipped = false
        func point(_ sample: PowerMeterCore.Measurement) -> NSPoint {
            NSPoint(x: area.minX + viewport.fraction(at: Double(sample.index) / hz) * area.width,
                    y: area.maxY - Double(sample.nanoamps / fullScaleNanoamps) * area.height)
        }
        for (offset, sample) in points.enumerated() {
            clipped = clipped || sample.nanoamps > fullScaleNanoamps
            if offset == 0 { line.move(to: point(sample)) } else { line.line(to: point(sample)) }
        }
        NSGraphicsContext.saveGraphicsState(); area.clip()
        NSColor.systemGreen.setStroke(); line.stroke()
        let sampleSpacing = visibleRange.count > 1 ? area.width / CGFloat(visibleRange.count - 1) : area.width
        if sampleSpacing >= 6, points.count == visibleRange.count {
            NSColor.systemGreen.setFill()
            for sample in points {
                let p = point(sample)
                NSBezierPath(ovalIn: NSRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)).fill()
            }
        }
        if points.count == 1, let sample = points.first {
            let p = point(sample); NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)).fill()
        }
        for (name, sample, color) in [("A", markerA, NSColor.systemOrange), ("B", markerB, NSColor.systemCyan)] {
            guard let sample, visibleRange.contains(sample.index) else { continue }
            let p = point(sample)
            let guide = NSBezierPath(); guide.move(to: NSPoint(x: p.x, y: area.minY)); guide.line(to: NSPoint(x: p.x, y: area.maxY))
            guide.setLineDash([4, 4], count: 2, phase: 0); color.setStroke(); guide.stroke()
            color.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill()
            label(name, at: NSPoint(x: min(p.x + 7, area.maxX - 16), y: max(area.minY + 4, min(p.y - 18, area.maxY - 18))), color: color)
        }
        NSGraphicsContext.restoreGraphicsState()
        if clipped { label("超出显示上限，请选择更大的电流刻度", at: NSPoint(x: area.minX + 8, y: area.minY + 8), color: .systemOrange) }
    }
}
