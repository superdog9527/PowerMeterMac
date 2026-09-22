import Foundation

/// Synchronous, append-only evidence for every control command. A request is
/// flushed before USB I/O, so a crash still leaves the last intended action.
public final class CommandAuditLog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private let handle: FileHandle

    public init(url: URL) throws {
        self.url = url
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw MeterError.message("无法创建安全操作日志：\(url.path)")
            }
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    public static func applicationLog() throws -> CommandAuditLog {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            throw MeterError.message("无法定位用户日志目录，拒绝连接设备")
        }
        return try CommandAuditLog(url: library.appendingPathComponent("Logs/PowerMeterMac/commands.jsonl"))
    }

    public func record(session: String, phase: String, opcode: UInt8? = nil,
                       payload: [UInt8] = [], result: Int? = nil, detail: String? = nil) throws {
        var object: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "session": session,
            "phase": phase
        ]
        if let opcode { object["opcode"] = String(format: "0x%02X", opcode) }
        if !payload.isEmpty { object["payload_hex"] = payload.map { String(format: "%02X", $0) }.joined() }
        if let result { object["result"] = result }
        if let detail { object["detail"] = detail }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0a)
        lock.lock(); defer { lock.unlock() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}
