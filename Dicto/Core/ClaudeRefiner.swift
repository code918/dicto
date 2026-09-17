import Foundation

/// `claude -p` (Claude Code CLI, 구독 인증)로 텍스트를 정제한다.
final class ClaudeRefiner {
    static func findClaude() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var workDir: URL {
        let dir = Settings.appSupportDir.appendingPathComponent("claude-work", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let queue = DispatchQueue(label: "com.lake514.dicto.claude", qos: .userInitiated)

    func refine(_ text: String, model: String, dictionary: [String], timeout: TimeInterval = 45) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try self.refineSync(text, model: model, dictionary: dictionary, timeout: timeout)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func refineSync(_ text: String, model: String, dictionary: [String], timeout: TimeInterval) throws -> String {
        guard let exe = Self.findClaude() else { throw DictoError.claudeNotFound }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.currentDirectoryURL = Self.workDir
        proc.arguments = [
            "-p",
            "--model", model,
            "--output-format", "text",
            "--tools", "",
            "--strict-mcp-config",
            "--no-session-persistence",
            "--setting-sources", "",
            "--system-prompt", RefinePrompt.system(dictionary: dictionary),
        ]
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        env["TERM"] = "dumb"
        proc.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        let start = Date()
        try proc.run()
        stdin.fileHandleForWriting.write(Data(RefinePrompt.userMessage(text).utf8))
        try? stdin.fileHandleForWriting.close()

        // 타임아웃
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if proc.isRunning { proc.terminate() } }
        timer.resume()
        defer { timer.cancel() }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let out = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let err = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        log.info("claude(\(model)) exit=\(proc.terminationStatus) in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")

        guard proc.terminationStatus == 0 else {
            let msg = (err.isEmpty ? out : err)
            if msg.lowercased().contains("not logged in") || msg.contains("/login") {
                throw DictoError.claudeFailed("로그인 안 됨. 터미널에서 `claude` 실행 후 /login")
            }
            throw DictoError.claudeFailed(msg.isEmpty ? "exit \(proc.terminationStatus)" : String(msg.prefix(200)))
        }
        guard !out.isEmpty else { return text }
        return Self.stripFences(out)
    }

    /// 모델이 가끔 ``` 로 감싸서 줄 때 대비
    private static func stripFences(_ s: String) -> String {
        var t = s
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
