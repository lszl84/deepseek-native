import Foundation
import Darwin

/// A child process in its own process group with merged stdout/stderr captured in memory
/// (bounded: keeps the head and a rolling tail).
final class ChildProcess {
    let pid: pid_t
    private let lock = NSLock()
    private var head = Data()
    private var tail = Data()
    private var droppedBytes = 0
    private var readOffsetTotal = 0   // bytes already returned by `readNew()`
    private var totalBytes = 0
    private(set) var exitCode: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var readSource: DispatchSourceRead?
    private var readFD: Int32
    private var spillHandle: FileHandle?
    let spillURL: URL
    private let headLimit = 64 * 1024
    private let tailLimit = 256 * 1024
    var onOutput: (() -> Void)?

    private init(pid: pid_t, readFD: Int32, spillURL: URL) {
        self.pid = pid
        self.readFD = readFD
        self.spillURL = spillURL
    }

    /// Spawns `argv` with `cwd` and `env`, stdin from /dev/null.
    static func spawn(_ argv: [String], cwd: String, env: [String: String]) throws -> ChildProcess {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw NSError(domain: "spawn", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "pipe failed"]) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])
        posix_spawn_file_actions_addchdir(&actions, cwd)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        // Reset signal handling to defaults in the child.
        var defSigs = sigset_t()
        sigfillset(&defSigs)
        posix_spawnattr_setsigdefault(&attr, &defSigs)
        var noMask = sigset_t()
        sigemptyset(&noMask)
        posix_spawnattr_setsigmask(&attr, &noMask)
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        posix_spawnattr_setflags(&attr, flags)

        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attr, cArgs, cEnv)
        close(fds[1])
        if rc != 0 {
            close(fds[0])
            throw NSError(domain: "spawn", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: "spawn failed: \(String(cString: strerror(rc)))"])
        }
        let spill = Paths.spill.appendingPathComponent("out-\(pid)-\(UUID().uuidString.prefix(8)).log")
        let p = ChildProcess(pid: pid, readFD: fds[0], spillURL: spill)
        p.start()
        return p
    }

    private func start() {
        let fd = readFD
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .utility))
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buf, buf.count)
                if n > 0 { self.ingest(Data(buf[0..<n])) }
                else if n == 0 { src.cancel(); break }
                else { if errno == EAGAIN || errno == EINTR { break }; src.cancel(); break }
            }
        }
        src.setCancelHandler { close(fd) }
        readSource = src
        src.resume()

        let pid = self.pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            // Let the pipe drain briefly (grandchildren may still hold it; do not wait on them forever).
            usleep(30_000)
            self?.finish(code)
        }
    }

    private func ingest(_ d: Data) {
        lock.lock()
        totalBytes += d.count
        if head.count < headLimit {
            let take = min(headLimit - head.count, d.count)
            head.append(d.prefix(take))
            if take < d.count { appendTail(d.suffix(from: d.startIndex + take)) }
        } else {
            appendTail(d)
        }
        if totalBytes > headLimit + tailLimit {
            if spillHandle == nil {
                FileManager.default.createFile(atPath: spillURL.path, contents: nil)
                spillHandle = try? FileHandle(forWritingTo: spillURL)
                // Rewrite what we still have; bytes already dropped are lost from the spill.
                try? spillHandle?.write(contentsOf: head)
                try? spillHandle?.write(contentsOf: tail)
            } else {
                try? spillHandle?.write(contentsOf: d)
            }
        }
        let cb = onOutput
        lock.unlock()
        cb?()
    }

    private func appendTail(_ d: Data) {
        tail.append(d)
        if tail.count > tailLimit {
            let drop = tail.count - tailLimit
            tail.removeFirst(drop)
            droppedBytes += drop
        }
    }

    private func finish(_ code: Int32) {
        lock.lock()
        exitCode = code
        let waiters = exitWaiters
        exitWaiters = []
        try? spillHandle?.close()
        lock.unlock()
        waiters.forEach { $0.resume(returning: code) }
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return exitCode == nil }

    /// Waits for exit up to `timeout` seconds; returns nil on timeout.
    func wait(timeout: Double?) async -> Int32? {
        if let c = exitCodeLocked() { return c }
        return await withTaskGroup(of: Int32?.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                    self.lock.lock()
                    if let c = self.exitCode { self.lock.unlock(); cont.resume(returning: c); return }
                    self.exitWaiters.append(cont)
                    self.lock.unlock()
                }
            }
            if let timeout {
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return nil
                }
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func exitCodeLocked() -> Int32? { lock.lock(); defer { lock.unlock() }; return exitCode }

    func terminate() {
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        let pid = self.pid
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.isRunning == true { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
        }
    }

    /// Complete captured output, with an elision marker when the middle was dropped.
    func output(maxChars: Int = 30_000) -> (text: String, truncated: Bool, spill: URL?) {
        lock.lock()
        let h = head, t = tail, dropped = droppedBytes, total = totalBytes
        let spilled = spillHandle != nil
        lock.unlock()
        var text = String(decoding: h, as: UTF8.self)
        if dropped > 0 { text += "\n… [\(dropped) bytes omitted] …\n" }
        text += String(decoding: t, as: UTF8.self)
        text = ANSI.strip(text)
        var truncated = false
        if text.count > maxChars {
            text = "… [output truncated to last \(maxChars) characters of \(total) bytes] …\n" + String(text.suffix(maxChars))
            truncated = true
        }
        return (text, truncated || dropped > 0, spilled ? spillURL : nil)
    }

    /// Output produced since the previous call.
    func readNew() -> String {
        lock.lock()
        defer { lock.unlock() }
        let all = head + tail
        let base = totalBytes - all.count
        let from = max(0, readOffsetTotal - base)
        readOffsetTotal = totalBytes
        guard from < all.count else { return "" }
        return ANSI.strip(String(decoding: all.suffix(from: all.startIndex + from), as: UTF8.self))
    }
}

enum ANSI {
    static func strip(_ s: String) -> String {
        guard s.contains("\u{1B}") || s.contains("\r") else { return s }
        var out = String()
        out.reserveCapacity(s.count)
        var it = s.unicodeScalars.makeIterator()
        var pendingCR = false
        while let c = it.next() {
            if c == "\u{1B}" {
                guard let n = it.next() else { break }
                if n == "[" {
                    while let x = it.next() { if (0x40...0x7E).contains(x.value) { break } }
                } else if n == "]" {
                    while let x = it.next() { if x == "\u{07}" || x == "\u{1B}" { break } }
                }
                continue
            }
            if c == "\r" { pendingCR = true; continue }
            if pendingCR {
                pendingCR = false
                if c != "\n" {
                    // Carriage-return overwrite: drop the current line so far.
                    if let nl = out.lastIndex(of: "\n") { out.removeSubrange(out.index(after: nl)...) } else { out.removeAll() }
                }
            }
            out.unicodeScalars.append(c)
        }
        return out
    }
}
