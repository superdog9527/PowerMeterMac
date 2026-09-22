import Foundation

public enum ChartAxis: Equatable { case x, y }

public enum EngineeringFormat {
    public static func current(nanoamps: Double, signed: Bool = false) -> String {
        let magnitude = abs(nanoamps)
        let scale: Double
        let unit: String
        if magnitude >= 1_000_000_000 { scale = 1_000_000_000; unit = "A" }
        else if magnitude >= 1_000_000 { scale = 1_000_000; unit = "mA" }
        else if magnitude >= 1_000 { scale = 1_000; unit = "µA" }
        else { scale = 1; unit = "nA" }
        return String(format: signed ? "%+.3f %@" : "%.3f %@", nanoamps / scale, unit)
    }

    public static func time(seconds: Double, signed: Bool = false) -> String {
        let magnitude = abs(seconds)
        let scale: Double
        let unit: String
        if magnitude == 0 || magnitude >= 1 { scale = 1; unit = "s" }
        else if magnitude >= 0.001 { scale = 0.001; unit = "ms" }
        else if magnitude >= 0.000_001 { scale = 0.000_001; unit = "µs" }
        else { scale = 0.000_000_001; unit = "ns" }
        return String(format: signed ? "%+.3f %@" : "%.3f %@", seconds / scale, unit)
    }
}

public enum AxisZoom {
    public static let durations: [Double] = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 30, 60]
    public static let currents: [Double] = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1e3, 2e3, 5e3, 1e4, 2e4, 5e4, 1e5, 2e5, 5e5, 1e6, 2e6, 5e6, 1e7, 2e7, 5e7, 1e8, 2e8, 5e8, 1e9, 2e9, 5e9]
    /// Axis bands exclude the plot interior and the bottom-left corner.
    public static func target(x: Double, y: Double, plotMinX: Double, plotMaxX: Double,
                              plotMinY: Double, plotMaxY: Double, width: Double, height: Double) -> ChartAxis? {
        guard x >= 0, y >= 0, x <= width, y <= height else { return nil }
        if x >= plotMinX && x <= plotMaxX && y >= plotMaxY { return .x }
        if x < plotMinX && y >= plotMinY && y < plotMaxY { return .y }
        return nil
    }
    public static func next(_ value: Double, inward: Bool, levels: [Double]) -> Double {
        if inward { return levels.last(where: { $0 < value * (1 - 1e-8) }) ?? levels.first! }
        return levels.first(where: { $0 > value * (1 + 1e-8) }) ?? levels.last!
    }
}

/// Coordinates are seconds from sample zero, never a fraction of the received count.
public struct TimeViewport {
    public private(set) var duration: Double
    public private(set) var start: Double = 0
    public private(set) var followsLatest = true
    public var end: Double { start + duration }
    public init(duration: Double = 10) { self.duration = duration }
    public mutating func setDuration(_ value: Double, earliest: Double, latest: Double) {
        guard value.isFinite, value > 0 else { return }
        duration = value; update(earliest: earliest, latest: latest)
    }
    public mutating func update(earliest: Double, latest: Double) {
        let upper = max(earliest, latest - duration)
        start = followsLatest ? upper : min(max(start, earliest), upper)
    }
    public mutating func move(to value: Double, earliest: Double, latest: Double) {
        followsLatest = false
        start = min(max(value, earliest), max(earliest, latest - duration))
    }
    public mutating func follow(earliest: Double, latest: Double) {
        followsLatest = true; update(earliest: earliest, latest: latest)
    }
    public mutating func zoom(to value: Double, anchorFraction: Double, earliest: Double, latest: Double) {
        guard value.isFinite, value > 0 else { return }
        let fraction = min(1, max(0, anchorFraction))
        let anchor = start + fraction * duration
        duration = value
        move(to: anchor - fraction * value, earliest: earliest, latest: latest)
    }
    public func fraction(at seconds: Double) -> Double { (seconds - start) / duration }
}

/// Bounded ring, shared only on the UI thread. No per-frame copy of the entire history.
public final class SampleHistory {
    private var values: [Float]
    public let capacity: Int
    public private(set) var endIndex: UInt64 = 0
    public private(set) var count = 0
    public var startIndex: UInt64 { endIndex - UInt64(count) }
    public init(capacity: Int = 6_000_000) {
        self.capacity = max(1, capacity)
        values = [Float](repeating: 0, count: max(1, capacity))
    }
    public func append(_ batch: [Measurement]) {
        for sample in batch {
            values[Int(endIndex % UInt64(capacity))] = sample.nanoamps
            endIndex += 1; count = min(count + 1, capacity)
        }
    }
    public func value(at index: UInt64) -> Float {
        precondition(index >= startIndex && index < endIndex)
        return values[Int(index % UInt64(capacity))]
    }
    public func reset() { endIndex = 0; count = 0 }
    public func snapshot() -> SampleHistory {
        let copy = SampleHistory(capacity: capacity)
        copy.values = values; copy.endIndex = endIndex; copy.count = count
        return copy
    }
    public func measurements() -> [Measurement] {
        (startIndex..<endIndex).map { Measurement(index: $0, nanoamps: value(at: $0)) }
    }
    /// Half-open visible interval: [start, end). Empty space contributes no samples.
    public func visibleRange(start: Double, end: Double, rate: Double) -> Range<UInt64> {
        let lower = min(endIndex, max(startIndex, UInt64(max(0, ceil(start * rate - 1e-7)))))
        let upper = min(endIndex, max(lower, UInt64(max(0, ceil(end * rate - 1e-7)))))
        return lower..<upper
    }
    public func average(in range: Range<UInt64>) -> Float? {
        guard !range.isEmpty else { return nil }
        var sum = 0.0
        for i in range { sum += Double(value(at: i)) }
        return Float(sum / Double(range.count))
    }
    public func nearest(to seconds: Double, rate: Double, in range: Range<UInt64>) -> Measurement? {
        guard !range.isEmpty else { return nil }
        let index = min(range.upperBound - 1, max(range.lowerBound, UInt64(max(0, (seconds * rate).rounded()))))
        return Measurement(index: index, nanoamps: value(at: index))
    }
    /// Keep actual first/extreme/last samples, in acquisition order. No synthetic Y or X.
    public func polyline(in range: Range<UInt64>, columns: Int) -> [Measurement] {
        guard !range.isEmpty else { return [] }
        let step = max(1, (range.count + max(1, columns) - 1) / max(1, columns))
        var result: [Measurement] = []
        var lower = range.lowerBound
        while lower < range.upperBound {
            let upper = min(range.upperBound, lower + UInt64(step))
            var low = lower, high = lower
            for i in lower..<upper {
                if value(at: i) < value(at: low) { low = i }
                if value(at: i) > value(at: high) { high = i }
            }
            for i in Set([lower, low, high, upper - 1]).sorted() {
                result.append(Measurement(index: i, nanoamps: value(at: i)))
            }
            lower = upper
        }
        return result
    }
}
