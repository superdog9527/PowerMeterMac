import Foundation

public struct Calibration: Codable, Equatable {
    public let offset: Double
    public let resistance: [Double]
    public init(offsetReply: [UInt8], tableReply: [UInt8]) throws {
        guard offsetReply.count == 15, offsetReply[12] == 0,
              tableReply.count == 895, tableReply[12] == 0 else { throw MeterError.message("校准应答不完整，禁止以默认参数代替") }
        let raw = offsetReply.u16(13)
        offset = Double(raw & 0x7fff) / (raw & 0x8000 == 0 ? 1 : 10)
        resistance = stride(from: 13, to: 895, by: 2).map { Double(tableReply.u16($0)) / 1_000_000 }
        guard offset <= 4095, resistance.allSatisfy({ $0 > 0 && $0 < 1 }) else { throw MeterError.message("校准参数超出有效范围") }
    }
    public init(offset: Double, resistance: [Double]) throws {
        guard offset.isFinite, (0...4095).contains(offset), resistance.count == 441,
              resistance.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1 }) else { throw MeterError.message("无效校准参数") }
        self.offset = offset; self.resistance = resistance
    }
    public func gains(millivolts: Int) throws -> [Double] {
        try SafetyPolicy.validate(millivolts: millivolts)
        let r = resistance[(millivolts - 600) / 10]
        var value = 0.001
        var result = [value]
        for shunt in [110.0, 11.0, 1.0, 0.1, 0.005] { value += 1 / (r + shunt); result.append(value) }
        return result
    }
}
public struct RawFrame {
    public let sequence: UInt16
    public let payload: [UInt8]
    public var sampleCount: Int { payload.count / 3 }
}
/// USB reads can contain a partial frame, multiple frames, or timeout data.
public struct FrameParser {
    private var pending: [UInt8] = []
    public private(set) var discardedBytes = 0
    public private(set) var sequenceAnomalies = 0
    private var previousSequence: UInt16?
    private var repeats = 0
    public init() {}
    public mutating func feed(_ bytes: [UInt8]) -> [RawFrame] {
        pending.append(contentsOf: bytes)
        var frames: [RawFrame] = [], cursor = 0
        while pending.count - cursor >= 6 {
            guard pending[cursor] == 0xed, pending[cursor + 1] == 0xde else { cursor += 1; discardedBytes += 1; continue }
            let length = Int(pending[cursor + 4]) | Int(pending[cursor + 5]) << 8
            guard length >= 9, length <= 3006, (length - 6) % 3 == 0 else { cursor += 1; discardedBytes += 1; continue }
            guard pending.count - cursor >= length else { break }
            let payload = Array(pending[(cursor + 6)..<(cursor + length)])
            // Range flags are 0, 1, 3, 7, 15 or 31; do not silently decode corrupt flags.
            guard stride(from: 0, to: payload.count, by: 3).allSatisfy({ [0, 1, 3, 7, 15, 31].contains(payload[$0]) }) else {
                discardedBytes += length; cursor += length; continue
            }
            let sequence = UInt16(pending[cursor + 2]) | UInt16(pending[cursor + 3]) << 8
            // V1.0.3 repeats each sequence twice. No hardware timestamps or per-sample counters.
            if let prev = previousSequence {
                if sequence == prev { repeats += 1; if repeats > 1 { sequenceAnomalies += 1 } }
                else { if sequence != prev &+ 1 { sequenceAnomalies += 1 }; repeats = 0 }
            }
            previousSequence = sequence
            frames.append(RawFrame(sequence: sequence, payload: payload)); cursor += length
        }
        if cursor > 0 { pending.removeFirst(cursor) }
        return frames
    }
    public var pendingBytes: Int { pending.count }
}
/// Mirrors SDK 20260911's calibrated ADC conversion and automatic range transition filter.
/// The DLL returns integral nanoamps converted to Float, not amps.
public struct CurrentDecoder {
    private let offset: Double
    private let gains: [Double]
    private var first = true
    private var previousRange: UInt8 = 255
    private var previous: UInt64 = 0
    private var risingPending = false
    private var rangeBeforeRise: UInt8 = 0
    public init(calibration: Calibration, millivolts: Int) throws {
        offset = Double(Float(calibration.offset)); gains = try calibration.gains(millivolts: millivolts)
    }
    private func nanoamps(_ range: UInt8, _ adc: Int) -> UInt64 {
        let index: Int
        switch range { case 1: index = 1; case 3: index = 2; case 7: index = 3; case 15: index = 4; case 31: index = 5; default: index = 0 }
        return UInt64(max(0, Double(adc) - offset) * 44322.344322344325 * gains[index])
    }
    public mutating func decode(_ frame: RawFrame) -> [Float] {
        var result: [Float] = []; result.reserveCapacity(frame.sampleCount)
        for i in stride(from: 0, to: frame.payload.count, by: 3) {
            let range = frame.payload[i], adc = frame.payload.u16(i + 1)
            let direct = nanoamps(range, adc)
            var value = direct
            if first { first = false }
            else if risingPending {
                risingPending = false
                if range > rangeBeforeRise { value = previous }
                // A canceled upward transition uses the last held value, as in the SDK.
                else { value = previous }
            } else if range > previousRange {
                risingPending = true; rangeBeforeRise = previousRange
                let oldRangeValue = nanoamps(previousRange, adc)
                value = max(oldRangeValue, previous)
                if value > previous * 5 { value = previous }
            } else if range < previousRange {
                value = previous > direct * 5 ? previous : direct
            }
            previous = value; previousRange = range
            result.append(Float(value))
        }
        return result
    }
}
public struct Downsampler {
    public let rate: SampleRate
    private var pending: [Float] = []
    public init(rate: SampleRate) { self.rate = rate }
    public mutating func process(_ values: [Float]) -> [Float] {
        guard rate != .k100 else { return values }
        pending.append(contentsOf: values)
        var result: [Float] = []; let factor = rate.factor
        result.reserveCapacity(pending.count / factor)
        var cursor = 0
        while cursor + factor <= pending.count {
            let group = pending[cursor..<(cursor + factor)]
            let sum = group.reduce(Float(0), +)
            if rate == .k10 { result.append((sum - group.max()! - group.min()!) * 0.125) }
            else { result.append(sum / Float(factor)) }
            cursor += factor
        }
        pending.removeFirst(cursor); return result
    }
}
