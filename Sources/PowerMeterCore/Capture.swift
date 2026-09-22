import Foundation

public struct Measurement: Sendable {
    public let index: UInt64
    public let nanoamps: Float
    public init(index: UInt64, nanoamps: Float) { self.index = index; self.nanoamps = nanoamps }
}

public struct MeasurementStatistics: Sendable {
    public var current: Float = 0
    public var average: Float = 0
    public var minimum: Float = 0
    public var maximum: Float = 0
    public var count: UInt64 = 0
    public var droppedFrames = 0

    public init() {}

    public var currentAmps: Double { Double(current) / 1_000_000_000 }
    public func powerWatts(millivolts: Int) -> Double {
        currentAmps * Double(millivolts) / 1000
    }
}

public final class CaptureEngine: @unchecked Sendable {
    public typealias Handler = @Sendable ([Measurement], MeasurementStatistics) -> Void

    private let device: USBDevice
    private let queue = DispatchQueue(label: "com.powermetermac.capture", qos: .userInitiated)
    private let workers = DispatchGroup()
    private let stateLock = NSLock()
    private var running = false
    private var generation: UInt64 = 0

    public init(device: USBDevice) { self.device = device }

    public func start(rate: SampleRate, handler: @escaping Handler, onError: @escaping @Sendable (Error) -> Void) throws {
        stateLock.lock()
        guard !running else { stateLock.unlock(); return }
        running = true
        generation &+= 1
        let myGeneration = generation
        stateLock.unlock()

        guard let millivolts = device.millivolts, let calibration = device.calibration else {
            stop()
            throw MeterError.message("请先设置安全电压")
        }
        do {
            try device.drain()
            try device.setCapture(true)
        } catch {
            finish(myGeneration)
            // A timeout can mean capture started but its acknowledgement was
            // lost. Force both capture and power output to a safe baseline.
            _ = device.emergencyStop(detail: "capture start failed: \(error.localizedDescription)")
            throw error
        }

        workers.enter()
        queue.async { [self] in
            defer { finish(myGeneration); workers.leave() }
            var parser = FrameParser()
            var decoder: CurrentDecoder
            do { decoder = try CurrentDecoder(calibration: calibration, millivolts: millivolts) }
            catch { onError(error); return }
            var downsampler = Downsampler(rate: rate)
            var index: UInt64 = 0, sum = 0.0
            var stats = MeasurementStatistics()
            do {
                while isRunning(myGeneration) {
                    let bytes = try device.read(timeout: 100)
                    if bytes.isEmpty { continue }
                    let frames = parser.feed(bytes)
                    for frame in frames {
                        let values = downsampler.process(decoder.decode(frame))
                        guard !values.isEmpty else { continue }
                        var batch: [Measurement] = []
                        batch.reserveCapacity(values.count)
                        for value in values {
                            batch.append(Measurement(index: index, nanoamps: value)); index &+= 1
                            sum += Double(value)
                            stats.current = value
                            stats.minimum = stats.count == 0 ? value : min(stats.minimum, value)
                            stats.maximum = stats.count == 0 ? value : max(stats.maximum, value)
                            stats.count &+= 1
                        }
                        stats.average = Float(sum / Double(stats.count))
                        stats.droppedFrames = parser.sequenceAnomalies
                        handler(batch, stats)
                    }
                }
            } catch {
                try? device.safeStop()
                onError(error)
            }
        }
    }

    public func stop() {
        stateLock.lock(); running = false; generation &+= 1; stateLock.unlock()
        try? device.setCapture(false)
        _ = workers.wait(timeout: .now() + 1)
    }

    private func isRunning(_ expected: UInt64) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running && generation == expected
    }

    private func finish(_ expected: UInt64) {
        stateLock.lock(); if generation == expected { running = false }; stateLock.unlock()
    }
}

public enum CSVExporter {
    public static func write(_ samples: [Measurement], rate: SampleRate, millivolts: Int, to url: URL) throws {
        var text = "sample,time_s,current_A,current_nA,voltage_V,power_W\n"
        text.reserveCapacity(samples.count * 70)
        let voltage = Double(millivolts) / 1000
        for sample in samples {
            let time = Double(sample.index) / Double(rate.rawValue)
            let amps = Double(sample.nanoamps) / 1_000_000_000
            text += "\(sample.index),\(time),\(amps),\(sample.nanoamps),\(voltage),\(amps * voltage)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
