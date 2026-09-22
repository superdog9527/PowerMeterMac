import Foundation
import CUSB

public enum MeterError: Error, LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}
public enum SafetyPolicy {
    public static let minimumMillivolts = 600 // SDK calibration table starts at 600 mV.
    public static let maximumMillivolts = 5000 // Product manual and device descriptor maximum.
    public static func validate(millivolts: Int) throws {
        guard (minimumMillivolts...maximumMillivolts).contains(millivolts) else {
            throw MeterError.message("电压必须为 600–5000 mV。")
        }
    }
    public static func millivolts(from text: String) throws -> Int {
        guard let v = Double(text), v.isFinite, v >= 0.6, v <= 5,
              abs(v * 1000 - (v * 1000).rounded()) < 0.000001 else {
            throw MeterError.message("请输入 0.600–5.000 V，步进为 0.001 V。")
        }
        let mv = Int((v * 1000).rounded()); try validate(millivolts: mv); return mv
    }
}
public enum SampleRate: Int, CaseIterable, Codable, Identifiable {
    case k10 = 10000, k20 = 20000, k50 = 50000, k100 = 100000
    public var id: Int { rawValue }
    public var label: String { "\(rawValue / 1000) kHz" }
    public var factor: Int { 100000 / rawValue }
}
extension Array where Element == UInt8 {
    func u16(_ offset: Int) -> Int { Int(self[offset]) | Int(self[offset + 1]) << 8 }
    func ascii(_ offset: Int, _ count: Int) -> String {
        String(bytes: self[offset..<(offset + count)].prefix { $0 != 0 }, encoding: .ascii) ?? "未知"
    }
}
public struct DeviceInfo: Codable, Equatable {
    public var model: Int
    public var serial: String
    public var maximumAmps: Int
    public var minimumNanoamps: Int
    public var minimumMillivolts: Int
    public var maximumVolts: Int
    public var hardware: String
    public var firmware: String
    public var manufactureDate: String
    public var name: String { "HH_PM_L\(model)" }
    public init(reply: [UInt8]) throws {
        guard reply.count == 47, reply[12] == 0 else { throw MeterError.message("设备信息应答长度不正确") }
        let p = Array(reply.dropFirst(13))
        model = Int(p[0]); serial = p.ascii(1, 9); maximumAmps = Int(p[10])
        minimumNanoamps = p.u16(11); minimumMillivolts = p.u16(13); maximumVolts = Int(p[15])
        hardware = p.ascii(16, 6); firmware = p.ascii(22, 6); manufactureDate = p.ascii(28, 6)
    }
}
// One owner, one worker queue. Never close this handle while a read is in progress.
public final class USBDevice {
    private var handle: OpaquePointer?
    private let audit: CommandAuditLog
    private let sessionID = UUID().uuidString
    public private(set) var info: DeviceInfo!
    public private(set) var calibration: Calibration!
    public private(set) var millivolts: Int?
    public private(set) var outputEnabled = false
    public private(set) var capturing = false
    public private(set) var commandLog: [String] = []
    public static func discover() throws -> [String] {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = pm_list(&buffer, Int32(buffer.count))
        guard result >= 0 else { throw MeterError.message(String(cString: pm_error(result))) }
        return String(cString: buffer).split(separator: "\n").map(String.init)
    }
    public init(serial: String = "", auditLog: CommandAuditLog? = nil) throws {
        if let auditLog { audit = auditLog } else { audit = try CommandAuditLog.applicationLog() }
        try audit.record(session: sessionID, phase: "session_open", detail: serial.isEmpty ? "auto" : serial)
        var error = [CChar](repeating: 0, count: 512)
        handle = serial.withCString { pm_open($0, &error, Int32(error.count)) }
        guard handle != nil else {
            try? audit.record(session: sessionID, phase: "open_failed", detail: String(cString: error))
            throw MeterError.message(String(cString: error))
        }
        do {
            // First attempt is deliberately best-effort: V1.0.3 may reject
            // control commands until identity has been queried after reset.
            try? setOutput(false)
            try? setCapture(false)
            // Firmware V1.0.3 requires an identity query before accepting control commands
            // after USB enumeration. Querying does not change output state.
            info = try DeviceInfo(reply: command(2))
            guard info.model == 2, info.hardware == "V1.0.0", info.firmware == "V1.0.3" else {
                throw MeterError.message("尚未验证的设备/固件：\(info.name) \(info.hardware) / \(info.firmware)。硬件状态未知，拒绝继续。")
            }
            // Authoritative safe baseline. Both acknowledgements are required
            // before calibration, voltage setting, capture, or output controls.
            try setOutput(false)
            try setCapture(false)
            let offset = try command(0x0d), table = try command(0x12)
            calibration = try Calibration(offsetReply: offset, tableReply: table)
            try audit.record(session: sessionID, phase: "ready_safe", detail: info.serial)
        } catch { close(); throw error }
    }
    deinit { close() }
    @discardableResult private func command(_ opcode: UInt8, _ payload: [UInt8] = []) throws -> [UInt8] {
        do { try audit.record(session: sessionID, phase: "request", opcode: opcode, payload: payload) }
        catch { throw MeterError.message("安全操作日志写入失败，命令未发送：\(error.localizedDescription)") }
        var response = [UInt8](repeating: 0, count: 16384)
        let n = payload.withUnsafeBufferPointer { p in pm_command(handle, opcode, p.baseAddress, Int32(p.count), &response, Int32(response.count)) }
        commandLog.append(String(format: "%@ op=%02x payload=%@ result=%d", ISO8601DateFormatter().string(from: Date()), opcode, payload.map { String(format: "%02x", $0) }.joined(), n))
        if commandLog.count > 256 { commandLog.removeFirst(commandLog.count - 256) }
        do { try audit.record(session: sessionID, phase: "response", opcode: opcode, payload: payload, result: Int(n)) }
        catch { throw MeterError.message("命令已发送但结果日志写入失败，硬件状态未知：\(error.localizedDescription)") }
        guard n >= 0 else { throw MeterError.message(String(format: "USB 命令 0x%02X：%@", opcode, String(cString: pm_error(n)))) }
        return Array(response.prefix(Int(n)))
    }
    public func setVoltage(_ value: Int) throws {
        try SafetyPolicy.validate(millivolts: value)
        let wasOutputEnabled = outputEnabled
        let deviceMinimum = max(SafetyPolicy.minimumMillivolts, info.minimumMillivolts)
        let deviceMaximum = min(SafetyPolicy.maximumMillivolts, info.maximumVolts * 1000)
        guard (deviceMinimum...deviceMaximum).contains(value) else {
            throw MeterError.message("本设备允许的电压范围为 \(deviceMinimum)–\(deviceMaximum) mV。")
        }
        guard !capturing else { throw MeterError.message("请先停止采集再调整电压") }
        do {
            try command(3, [UInt8(value & 255), UInt8(value >> 8)])
            millivolts = value
        } catch {
            // A timeout after transmission makes the device setpoint unknown.
            // If output was already live, immediately force it off rather than
            // leaving an unknown voltage applied to the load.
            millivolts = nil
            if wasOutputEnabled {
                let stopped = emergencyStop(detail: "live voltage change failed: \(error.localizedDescription)")
                if !stopped { throw MeterError.message("修改输出电压结果未知，紧急关断也未确认。请立即断开仪器电源。") }
            }
            throw error
        }
    }
    public func setOutput(_ enabled: Bool) throws {
        if enabled {
            guard !capturing, let mv = millivolts else { throw MeterError.message("请先设置并确认安全电压") }
            try SafetyPolicy.validate(millivolts: mv)
        }
        if enabled {
            do { try command(5, [1]); outputEnabled = true }
            catch {
                // An enable timeout is ambiguous: the device may have acted but
                // lost its reply. Bypass the logger for one final OFF attempt.
                let stopped = emergencyStop(detail: "enable failed: \(error.localizedDescription)")
                if !stopped { throw MeterError.message("开启输出结果未知，紧急关断也未确认。请立即断开仪器电源。") }
                throw error
            }
        } else {
            try command(6, [0]); outputEnabled = false
        }
    }
    public func setCapture(_ enabled: Bool) throws {
        if enabled {
            guard millivolts != nil, calibration != nil else { throw MeterError.message("尚未完成安全电压设置和校准读取") }
            try command(0x10, [10]) // Official SDK always programs the hardware to 100 kHz.
        }
        try command(enabled ? 7 : 8, [enabled ? 1 : 0]); capturing = enabled
    }
    public func read(timeout: Int = 50) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 16384)
        let n = pm_read(handle, &buffer, Int32(buffer.count), Int32(timeout))
        guard n >= 0 else { throw MeterError.message(String(cString: pm_error(n))) }
        return Array(buffer.prefix(Int(n)))
    }
    public func drain() throws {
        for _ in 0..<50 { if try read(timeout: 10).isEmpty { return } }
        throw MeterError.message("停止后仍收到连续数据，无法建立新的采集边界")
    }
    /// Output OFF is attempted even if capture STOP fails (and vice versa).
    public func safeStop() throws {
        var errors: [String] = []
        do { try setOutput(false) } catch { errors.append("关闭输出：\(error.localizedDescription)") }
        do { try setCapture(false) } catch { errors.append("停止采集：\(error.localizedDescription)") }
        if !errors.isEmpty {
            let emergencySucceeded = emergencyStop(detail: errors.joined(separator: "；"))
            let suffix = emergencySucceeded ? "；底层紧急关断已确认，但常规命令或日志异常。" : "；紧急关断也未确认，硬件状态未知，请立即断开仪器电源。"
            throw MeterError.message(errors.joined(separator: "；") + suffix)
        }
    }
    /// Last-resort commands bypass persistent logging, used only when the
    /// normal logged path cannot prove the hardware state.
    @discardableResult public func emergencyStop(detail: String) -> Bool {
        guard handle != nil else { return true }
        var response = [UInt8](repeating: 0, count: 16384), zero: UInt8 = 0
        let outputResult = pm_command(handle, 6, &zero, 1, &response, Int32(response.count))
        let captureResult = pm_command(handle, 8, &zero, 1, &response, Int32(response.count))
        if outputResult >= 0 { outputEnabled = false }
        if captureResult >= 0 { capturing = false }
        try? audit.record(session: sessionID, phase: "emergency_stop", result: outputResult >= 0 && captureResult >= 0 ? 0 : -1,
                          detail: "output=\(outputResult), capture=\(captureResult), cause=\(detail)")
        return outputResult >= 0 && captureResult >= 0
    }
    public func close() {
        if let h = handle {
            try? audit.record(session: sessionID, phase: "close_fallback", detail: "底层将再次尝试关闭输出和采集")
            pm_close(h); handle = nil
        }
        capturing = false; outputEnabled = false; millivolts = nil
    }
}
