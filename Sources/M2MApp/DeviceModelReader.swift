import Darwin
import Foundation

enum DeviceModelReader {
    static func localModelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    static func remoteModelIdentifier(host: String) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=2",
                "kivi@\(host)",
                "/usr/sbin/sysctl -n hw.model",
            ]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    static func displayName(for identifier: String?, fallback: String) -> String {
        guard let identifier else { return fallback }
        if identifier.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if identifier.hasPrefix("MacBookAir") { return "MacBook Air" }
        if identifier.hasPrefix("iMac") { return "iMac" }
        if identifier.hasPrefix("Macmini") { return "Mac mini" }
        if identifier.hasPrefix("MacStudio") { return "Mac Studio" }
        if identifier.hasPrefix("MacPro") { return "Mac Pro" }
        return identifier
    }
}
