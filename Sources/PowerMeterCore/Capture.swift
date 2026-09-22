import Foundation

public struct Measurement: Sendable {
    public let index: UInt64
    public let nanoamps: Float
    public let millivolts: Int?
    public init(index: UInt64, nanoamps: Float, millivolts: Int? = nil) {
        self.index = index; self.nanoamps = nanoamps; self.millivolts = millivolts
    }
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
    private var voltageRequest: VoltageRequest?

    private final class VoltageRequest: @unchecked Sendable {
        let millivolts: Int
        let completed = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>?
        init(millivolts: Int) { self.millivolts = millivolts }
        func finish(_ result: Result<Void, Error>) { self.result = result; completed.signal() }
    }

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
            var activeMillivolts = millivolts
            var index: UInt64 = 0, sum = 0.0
            var stats = MeasurementStatistics()
            do {
                while isRunning(myGeneration) {
                    if let request = takeVoltageRequest(myGeneration) {
                        do {
                            // Keep power output enabled, but establish a clean sample/calibration
                            // boundary so buffered old-voltage data is never decoded as new-voltage data.
                            try device.setCapture(false)
                            try device.drain()
                            try device.setVoltage(request.millivolts)
                            decoder = try CurrentDecoder(calibration: calibration, millivolts: request.millivolts)
                            parser = FrameParser()
                            downsampler = Downsampler(rate: rate)
                            try device.setCapture(true)
                            activeMillivolts = request.millivolts
                            request.finish(.success(()))
                        } catch {
                            _ = device.emergencyStop(detail: "dynamic voltage change failed: \(error.localizedDescription)")
                            request.finish(.failure(error))
                            return
                        }
                    }
                    let bytes = try device.read(timeout: 100)
                    if bytes.isEmpty { continue }
                    let frames = parser.feed(bytes)
                    for frame in frames {
                        let values = downsampler.process(decoder.decode(frame))
                        guard !values.isEmpty else { continue }
                        var batch: [Measurement] = []
                        batch.reserveCapacity(values.count)
                        for value in values {
                            batch.append(Measurement(index: index, nanoamps: value, millivolts: activeMillivolts)); index &+= 1
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
        stateLock.lock()
        running = false; generation &+= 1
        let request = voltageRequest; voltageRequest = nil
        stateLock.unlock()
        request?.finish(.failure(MeterError.message("采集已停止，电压未修改")))
        try? device.setCapture(false)
        _ = workers.wait(timeout: .now() + 1)
    }

    /// Changes output voltage while preserving the current capture session and output state.
    /// The capture worker briefly stops acquisition and drains old samples before switching
    /// decoder calibration and resuming at the next sample index.
    public func changeVoltage(to millivolts: Int) throws {
        try SafetyPolicy.validate(millivolts: millivolts)
        let request = VoltageRequest(millivolts: millivolts)
        stateLock.lock()
        guard running else { stateLock.unlock(); throw MeterError.message("采集未运行") }
        guard voltageRequest == nil else { stateLock.unlock(); throw MeterError.message("已有电压修改正在进行") }
        voltageRequest = request
        stateLock.unlock()
        guard request.completed.wait(timeout: .now() + 15) == .success else {
            stateLock.lock()
            if voltageRequest === request { voltageRequest = nil }
            running = false; generation &+= 1
            stateLock.unlock()
            _ = device.emergencyStop(detail: "dynamic voltage change timed out")
            throw MeterError.message("动态修改电压超时，硬件状态未知，请立即关闭输出并检查设备")
        }
        try request.result!.get()
    }

    private func isRunning(_ expected: UInt64) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running && generation == expected
    }

    private func takeVoltageRequest(_ expected: UInt64) -> VoltageRequest? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard running, generation == expected else { return nil }
        let request = voltageRequest; voltageRequest = nil; return request
    }

    private func finish(_ expected: UInt64) {
        stateLock.lock()
        var request: VoltageRequest?
        if generation == expected { running = false; request = voltageRequest; voltageRequest = nil }
        stateLock.unlock()
        request?.finish(.failure(MeterError.message("采集已结束，电压未修改")))
    }
}

public enum CSVExporter {
    public static func write(_ samples: [Measurement], rate: SampleRate, millivolts: Int, to url: URL) throws {
        var text = "sample,time_s,current_A,current_nA,voltage_V,power_W\n"
        text.reserveCapacity(samples.count * 70)
        for sample in samples {
            let time = Double(sample.index) / Double(rate.rawValue)
            let amps = Double(sample.nanoamps) / 1_000_000_000
            let voltage = Double(sample.millivolts ?? millivolts) / 1000
            text += "\(sample.index),\(time),\(amps),\(sample.nanoamps),\(voltage),\(amps * voltage)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
