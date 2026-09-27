import Foundation

/// A background job: a shell process or an asynchronous task such as a subagent.
final class Job {
    enum Kind: String { case bash, subagent }
    enum State: String { case running, completed, failed, killed }

    let id: String
    let kind: Kind
    let label: String
    let startedAt = Date()
    fileprivate(set) var state: State = .running
    fileprivate(set) var finishedAt: Date?
    fileprivate(set) var result: String?
    fileprivate var process: ChildProcess?
    fileprivate var task: Task<Void, Never>?
    fileprivate var collected = false

    init(id: String, kind: Kind, label: String) {
        self.id = id
        self.kind = kind
        self.label = label
    }
}

final class JobManager {
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var counter = 0
    /// Called (off the main thread) when a job finishes on its own.
    var onFinish: ((Job) -> Void)?

    private func nextId(_ prefix: String) -> String {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return "\(prefix)-\(counter)"
    }

    private func add(_ job: Job) {
        lock.lock(); jobs[job.id] = job; order.append(job.id); lock.unlock()
    }

    func job(_ id: String) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs[id] }

    var runningCount: Int { lock.lock(); defer { lock.unlock() }; return jobs.values.filter { $0.state == .running }.count }

    /// Adopts a running process as a background job.
    @discardableResult
    func adopt(_ process: ChildProcess, label: String) -> Job {
        let job = Job(id: nextId("bash"), kind: .bash, label: label)
        job.process = process
        add(job)
        Task.detached { [weak self] in
            let code = await process.wait(timeout: nil) ?? -1
            self?.complete(job, state: job.state == .killed ? .killed : (code == 0 ? .completed : .failed), result: "[exit code: \(code)]")
        }
        return job
    }

    /// Runs `body` as a background job; its return value becomes the job result.
    @discardableResult
    func start(kind: Job.Kind, label: String, body: @escaping () async -> (String, Bool)) -> Job {
        let job = Job(id: nextId(kind.rawValue), kind: kind, label: label)
        add(job)
        job.task = Task.detached { [weak self] in
            let (text, ok) = await body()
            self?.complete(job, state: Task.isCancelled ? .killed : (ok ? .completed : .failed), result: text)
        }
        return job
    }

    private func complete(_ job: Job, state: Job.State, result: String) {
        lock.lock()
        guard job.state == .running || job.state == .killed else { lock.unlock(); return }
        let wasKilled = job.state == .killed
        if job.finishedAt != nil { lock.unlock(); return }
        job.state = wasKilled ? .killed : state
        job.result = result
        job.finishedAt = Date()
        lock.unlock()
        if !wasKilled { onFinish?(job) }
    }

    func kill(_ id: String) -> String {
        guard let job = job(id) else { return "No job with id \(id)." }
        guard job.state == .running else { return "Job \(id) already \(job.state.rawValue)." }
        lock.lock(); job.state = .killed; lock.unlock()
        job.process?.terminate()
        job.task?.cancel()
        return "Cancellation requested for job \(id)."
    }

    func killAll() {
        lock.lock(); let ids = order; lock.unlock()
        for id in ids where job(id)?.state == .running { _ = kill(id) }
    }

    func list() -> String {
        lock.lock(); let all = order.compactMap { jobs[$0] }; lock.unlock()
        if all.isEmpty { return "No background jobs." }
        return all.map { j in
            let dur = Int((j.finishedAt ?? Date()).timeIntervalSince(j.startedAt))
            return "\(j.id)\t\(j.kind.rawValue)\t\(j.state.rawValue)\t\(dur)s\t\(j.label)"
        }.joined(separator: "\n")
    }

    func output(_ id: String, wait: Bool, timeoutMs: Int?) async -> (String, Bool) {
        guard let job = job(id) else { return ("No job with id \(id).", false) }
        if wait && job.state == .running {
            let timeout = Double(min(timeoutMs ?? 600_000, 3_600_000)) / 1000
            if let p = job.process {
                _ = await p.wait(timeout: timeout)
            } else {
                let deadline = Date().addingTimeInterval(timeout)
                while job.state == .running && Date() < deadline && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
        let (state, result) = lock.withLock { () -> (Job.State, String?) in job.collected = true; return (job.state, job.result) }
        var shown = state
        var exitNote = result
        if state == .running, let p = job.process, let code = p.exitCode {
            // The exit watcher may not have recorded completion yet.
            shown = code == 0 ? .completed : .failed
            exitNote = "[exit code: \(code)]"
        }
        var text = "Job \(id) (\(job.kind.rawValue)): \(shown.rawValue)\n"
        if let p = job.process {
            let new = p.readNew()
            text += new.isEmpty ? "(no new output)" : String(new.suffix(30_000))
            if shown != .running, let r = exitNote { text += "\n" + r }
        } else if let r = result {
            text += r
        } else {
            text += "(still running)"
        }
        return (text, true)
    }
}
