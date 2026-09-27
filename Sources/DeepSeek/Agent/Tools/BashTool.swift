import Foundation

enum ShellEnvironment {
    /// The user's login-shell PATH, resolved once at startup (GUI apps inherit a minimal PATH).
    private static var loginPath: String?
    private static let lock = NSLock()

    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            guard let p = try? ChildProcess.spawn([shell, "-l", "-c", "printf %s \"$PATH\""], cwd: NSHomeDirectory(), env: ProcessInfo.processInfo.environment) else { return }
            Task {
                if await p.wait(timeout: 5) != nil {
                    let path = p.output().text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !path.isEmpty { lock.withLock { loginPath = path } }
                } else { p.terminate() }
            }
        }
    }

    static func environment(cwd: String, sessionId: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let lp = lock.withLock { loginPath }
        var path = lp ?? env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"] where !path.split(separator: ":").contains(Substring(extra)) {
            path = extra + ":" + path
        }
        env["PATH"] = path
        env["PWD"] = cwd
        env["TERM"] = "dumb"
        env["PAGER"] = "cat"
        env["GIT_PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["NO_COLOR"] = "1"
        env["DSH_WORKSPACE"] = cwd
        env["DSH_SESSION_ID"] = sessionId
        env["DSH_APP"] = "deepseek-native"
        env.removeValue(forKey: "__CFBundleIdentifier")
        env.removeValue(forKey: "XPC_SERVICE_NAME")
        return env
    }
}

enum Sandbox {
    static let available = FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")

    private static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func profile(mode: PermissionMode, cwd: String) -> String {
        let home = NSHomeDirectory()
        var writable = ["/dev", "/private/tmp", "/private/var/folders", "/tmp", NSTemporaryDirectory()]
        for d in [".cache", "Library/Caches", ".npm", ".pnpm-store", "Library/pnpm", ".local/share/pnpm", ".yarn", ".bun",
                  ".cargo", ".rustup", "go", ".gradle", ".m2", ".swiftpm", "Library/Developer/Xcode/DerivedData",
                  "Library/org.swift.swiftpm", ".node-gyp", ".deno", ".config/configstore"] {
            writable.append((home as NSString).appendingPathComponent(d))
        }
        if mode == .workspaceWrite {
            writable.append(cwd)
            writable.append(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path)
        }
        let rules = Set(writable).sorted().map { "(subpath \(q($0)))" }.joined(separator: " ")
        return """
        (version 1)
        (allow default)
        (deny file-write*)
        (allow file-write* \(rules))
        """
    }

    static func wrap(_ argv: [String], mode: PermissionMode, cwd: String) -> [String] {
        guard available, mode != .fullAccess else { return argv }
        return ["/usr/bin/sandbox-exec", "-p", profile(mode: mode, cwd: cwd)] + argv
    }
}

struct BashTool: AgentTool {
    let name = "bash"
    let description = "Execute a bash command (`bash -c`) and return its stdout/stderr. Each call runs in a fresh shell; pass `workdir` instead of using `cd`. Managed `$DSH_*` variables expose current harness environment facts. Long output is truncated to its tail; the full output is saved to a file whose path is reported when available. Commands may run under a file sandbox; a blocked file operation is reported as `Operation not permitted`, a policy denial: do not retry another way."
    let schema = DeepSeek.schema("""
    {"type":"object","properties":{"command":{"type":"string","description":"The bash command to execute."},"description":{"type":"string","description":"Clear, concise description of what this command does in active voice, 5-10 words (shown in the UI). Examples: \\"ls\\" → \\"List files in current directory\\"; \\"git status\\" → \\"Show working tree status\\"; \\"npm install\\" → \\"Install package dependencies\\"."},"timeoutMs":{"type":"number","description":"Timeout in milliseconds. The executor applies its configured default and cap; on expiry the command moves to the background as a job instead of being killed."},"workdir":{"type":"string","description":"Working directory for this command. Defaults to the session workspace; a relative path is resolved against it."},"run_in_background":{"type":"boolean","description":"Run in the background and return a job id immediately (collect with job_output, stop with job_kill). No timeout applies."}},"required":["command","description"]}
    """)

    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult {
        guard let command = input["command"]?.string, !command.trimmingCharacters(in: .whitespaces).isEmpty else { return .error("command is required") }
        let workdir = ctx.resolve(input["workdir"]?.string)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workdir, isDirectory: &isDir), isDir.boolValue else { return .error("workdir does not exist: \(workdir)") }
        let mode = await MainActor.run { ctx.session.permission }
        if mode != .fullAccess && !Sandbox.available {
            let ok = await ctx.requestApproval(title: "Run command without sandbox?", detail: command, key: "bash:\(command)")
            if !ok { return .error("The user denied this command.") }
        }
        let argv = Sandbox.wrap(["/bin/bash", "-c", command], mode: mode, cwd: ctx.cwd)
        let env = ShellEnvironment.environment(cwd: workdir, sessionId: ctx.session.id)
        let proc: ChildProcess
        do { proc = try ChildProcess.spawn(argv, cwd: workdir, env: env) } catch {
            return .error("Failed to start command: \(error.localizedDescription)")
        }
        let label = input["description"]?.string ?? String(command.prefix(80))
        if input["run_in_background"]?.bool == true {
            let job = ctx.jobs.adopt(proc, label: label)
            ctx.setMeta(["job": .string(job.id)])
            return ToolResult(text: "Started background job \(job.id). Collect output with job_output, stop with job_kill.", meta: ["job": .string(job.id)])
        }

        // Stream a live tail of the output into the UI, throttled.
        let throttle = Throttle(interval: 0.25)
        proc.onOutput = { [weak proc] in
            throttle.run {
                guard let proc else { return }
                ctx.progress(String(proc.output(maxChars: 4000).text.suffix(4000)))
            }
        }
        let requested = input["timeoutMs"]?.double.map { $0 / 1000 } ?? Double(Settings.shared.bashTimeoutMs) / 1000
        let timeout = min(max(requested, 1), 600)
        let code: Int32? = await withTaskCancellationHandler {
            await proc.wait(timeout: timeout)
        } onCancel: {
            proc.terminate()
        }
        proc.onOutput = nil
        if Task.isCancelled {
            proc.terminate()
            let out = proc.output()
            return ToolResult(text: out.text + "\n[interrupted by the user]", isError: true)
        }
        guard let code else {
            let job = ctx.jobs.adopt(proc, label: label)
            let out = proc.output(maxChars: 8000)
            ctx.setMeta(["job": .string(job.id)])
            return ToolResult(text: "Command still running after \(Int(timeout))s; it moved to the background as job \(job.id). Collect with job_output, stop with job_kill.\nOutput so far:\n\(out.text)",
                              meta: ["job": .string(job.id)])
        }
        let out = proc.output()
        var text = out.text
        if text.isEmpty { text = "(no output)" }
        if let spill = out.spill { text += "\n[full output saved to \(spill.path)]" }
        text += "\n[exit code: \(code)]"
        return ToolResult(text: text, isError: false, meta: ["exitCode": .number(Double(code))])
    }
}

/// Runs at most one closure per interval (trailing edge), off the calling thread.
final class Throttle {
    private let interval: Double
    private let lock = NSLock()
    private var scheduled = false
    private var latest: (() -> Void)?

    init(interval: Double) { self.interval = interval }

    func run(_ f: @escaping () -> Void) {
        lock.lock()
        latest = f
        if scheduled { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let f = self.latest
            self.latest = nil
            self.scheduled = false
            self.lock.unlock()
            f?()
        }
    }
}
