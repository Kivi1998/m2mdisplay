import Foundation

struct LifecycleScriptResult: Sendable {
    let succeeded: Bool
    let detail: String
}

/// 图形界面与命令行共用同一组一键脚本，避免两套启动、退出逻辑逐渐产生差异。
/// 脚本在正式 App 中位于 Contents/Resources，开发运行时则回退到仓库 scripts。
final class PeerLifecycleScripts {
    func startReceiver() async -> LifecycleScriptResult {
        await run(
            scriptName: "m2m-start-all.sh",
            arguments: ["--peer-only"],
            environment: [
                "M2M_PEER_SSH": "kivi@10.10.10.2",
                "M2M_PEER_APP": "/Applications/M2MApp.app",
                "M2M_PEER_ROLE": "receiver",
            ]
        )
    }

    func stopPeer(host: String) async -> LifecycleScriptResult {
        await run(
            scriptName: "m2m-stop-all.sh",
            arguments: ["--peer-only"],
            environment: ["M2M_PEER_HOST": host]
        )
    }

    private func run(
        scriptName: String,
        arguments: [String],
        environment additions: [String: String]
    ) async -> LifecycleScriptResult {
        guard let scriptURL = locate(scriptName) else {
            return LifecycleScriptResult(succeeded: false, detail: "找不到生命周期脚本：\(scriptName)")
        }

        return await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            let errorOutput = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path] + arguments
            process.standardOutput = output
            process.standardError = errorOutput
            process.environment = ProcessInfo.processInfo.environment.merging(additions) { _, new in new }

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return LifecycleScriptResult(succeeded: false, detail: "无法运行脚本：\(error)")
            }

            let standardOutput = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let standardError = String(data: errorOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let detail = [standardOutput, standardError]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return LifecycleScriptResult(succeeded: process.terminationStatus == 0, detail: detail)
        }.value
    }

    private func locate(_ scriptName: String) -> URL? {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent(scriptName),
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }

        let developmentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts")
            .appendingPathComponent(scriptName)
        return FileManager.default.fileExists(atPath: developmentURL.path) ? developmentURL : nil
    }
}
