import Foundation

public enum EventLogLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

/// 持久化的带时间戳事件日志，每个角色一个文件，存放在
/// ~/Library/Logs/M2MDisplay/ 下。取代之前用 `nohup` 把进程 stdout
/// 导到一次性 /tmp 文件的做法——那种方式重启就没了，还得 SSH 上去才能看。
public final class EventLog {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.m2mdisplay.eventlog")

    /// 每次写入后在主线程触发，供界面的"最近事件"列表使用。
    public var onEvent: ((String) -> Void)?

    public init(role: String) {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/M2MDisplay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("\(role).log")
    }

    public func write(_ level: EventLogLevel, _ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
        queue.async { [fileURL] in
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
        fputs(line, stderr)
        DispatchQueue.main.async { [weak self] in self?.onEvent?(message) }
    }
}
