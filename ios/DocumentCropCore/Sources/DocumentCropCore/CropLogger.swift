import Foundation
import os

/// Ring buffer of crop pipeline messages — shown in-app and mirrored to Console.
public final class CropLogger: @unchecked Sendable {
    public static let shared = CropLogger()

    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 300
    private let osLog = Logger(subsystem: "com.snathany.Margin", category: "Crop")

    private init() {}

    public func info(_ message: String) {
        append("ℹ️", message)
    }

    public func success(_ message: String) {
        append("✅", message)
    }

    public func warn(_ message: String) {
        append("⚠️", message)
    }

    public func error(_ message: String) {
        append("❌", message)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
    }

    public func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    public var joined: String {
        snapshot().joined(separator: "\n")
    }

    private func append(_ prefix: String, _ message: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        let line = "[\(stamp)] \(prefix) \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        lock.unlock()
        osLog.info("\(line, privacy: .public)")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
