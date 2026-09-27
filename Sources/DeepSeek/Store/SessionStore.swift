import Foundation

struct Workspace: Codable, Equatable {
    var id: String
    var path: String
    var title: String { (path as NSString).lastPathComponent }
    var collapsed: Bool?
}

struct SessionIndexEntry: Codable, Equatable {
    var id: String
    var cwd: String
    var title: String
    var createdAt: Double
    var updatedAt: Double
    var archived: Bool?
    var pinned: Bool?
}

/// Workspace list and session index; the transcripts themselves live in per-session JSONL files.
final class SessionStore {
    static let shared = SessionStore()
    static let didChange = Notification.Name("SessionStoreDidChange")

    private struct FileModel: Codable {
        var workspaces: [Workspace]
        var sessions: [SessionIndexEntry]
        var lastWorkspaceId: String?
    }

    private(set) var workspaces: [Workspace] = []
    private(set) var index: [SessionIndexEntry] = []
    var lastWorkspaceId: String? { didSet { save() } }
    private var live: [String: Session] = [:]
    private var saveScheduled = false

    private init() {
        if let data = try? Data(contentsOf: Paths.workspacesFile), let m = try? JSONDecoder().decode(FileModel.self, from: data) {
            workspaces = m.workspaces
            index = m.sessions
            lastWorkspaceId = m.lastWorkspaceId
        }
        // Drop index entries whose files disappeared.
        index.removeAll { !FileManager.default.fileExists(atPath: Paths.sessions.appendingPathComponent($0.id + ".jsonl").path) }
    }

    private func save() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted]
            if let data = try? enc.encode(FileModel(workspaces: self.workspaces, sessions: self.index, lastWorkspaceId: self.lastWorkspaceId)) {
                try? data.write(to: Paths.workspacesFile, options: .atomic)
            }
        }
    }

    private func changed() {
        save()
        NotificationCenter.default.post(name: SessionStore.didChange, object: self)
    }

    // MARK: Workspaces

    @discardableResult
    func addWorkspace(path: String) -> Workspace {
        let p = (path as NSString).standardizingPath
        if let w = workspaces.first(where: { $0.path == p }) { return w }
        let w = Workspace(id: UUID().uuidString, path: p)
        workspaces.append(w)
        changed()
        return w
    }

    func removeWorkspace(_ id: String) {
        workspaces.removeAll { $0.id == id }
        changed()
    }

    func setCollapsed(_ id: String, _ collapsed: Bool) {
        if let i = workspaces.firstIndex(where: { $0.id == id }) { workspaces[i].collapsed = collapsed; save() }
    }

    func workspace(id: String?) -> Workspace? { workspaces.first { $0.id == id } }
    func workspace(forPath path: String) -> Workspace? { workspaces.first { $0.path == path } }

    func sessions(in workspace: Workspace, includeArchived: Bool = false) -> [SessionIndexEntry] {
        index.filter { $0.cwd == workspace.path && (includeArchived || $0.archived != true) }
            .sorted { ($0.pinned == true ? 1 : 0, $0.updatedAt) > ($1.pinned == true ? 1 : 0, $1.updatedAt) }
    }

    // MARK: Sessions

    func newSession(cwd: String) -> Session {
        let s = Session(cwd: cwd)
        live[s.id] = s
        return s
    }

    /// Registers a session in the index once it has content.
    func register(_ s: Session) {
        if let i = index.firstIndex(where: { $0.id == s.id }) {
            index[i].title = s.title
            index[i].updatedAt = s.updatedAt
        } else {
            index.append(SessionIndexEntry(id: s.id, cwd: s.cwd, title: s.title, createdAt: s.createdAt, updatedAt: s.updatedAt))
            if workspace(forPath: s.cwd) == nil { addWorkspace(path: s.cwd) }
        }
        changed()
    }

    /// Registers an imported session file (thread-safe: hops to main).
    func addImported(_ e: SessionIndexEntry) {
        let apply = {
            guard !self.index.contains(where: { $0.id == e.id }) else { return }
            self.index.append(e)
            if self.workspace(forPath: e.cwd) == nil { self.addWorkspace(path: e.cwd) }
            self.changed()
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.sync(execute: apply) }
    }

    func sessionMetaChanged(_ s: Session) {
        guard let i = index.firstIndex(where: { $0.id == s.id }) else { return }
        index[i].title = s.title
        index[i].updatedAt = s.updatedAt
        changed()
    }

    func session(id: String) -> Session? {
        if let s = live[id] { return s }
        guard let e = index.first(where: { $0.id == id }) else { return nil }
        let s = Session(existingId: e.id, cwd: e.cwd, title: e.title, updatedAt: e.updatedAt, createdAt: e.createdAt)
        live[id] = s
        return s
    }

    func entry(id: String) -> SessionIndexEntry? { index.first { $0.id == id } }

    var runningSessions: [Session] { live.values.filter { $0.isRunning } }

    /// Frees memory of idle sessions other than `keep`.
    func trim(keep: String?) {
        for (id, s) in live where id != keep && !s.isRunning {
            if index.contains(where: { $0.id == id }) { s.unload(); live[id] = nil }
        }
    }

    func rename(_ id: String, to title: String) {
        if let s = live[id] { s.setTitle(title) }
        else if let i = index.firstIndex(where: { $0.id == id }) {
            index[i].title = title
            let s = session(id: id)
            s?.setTitle(title)
            changed()
        }
    }

    func setArchived(_ id: String, _ v: Bool) {
        if let i = index.firstIndex(where: { $0.id == id }) { index[i].archived = v; changed() }
    }

    func setPinned(_ id: String, _ v: Bool) {
        if let i = index.firstIndex(where: { $0.id == id }) { index[i].pinned = v; changed() }
    }

    func delete(_ id: String) {
        let s = session(id: id)
        s?.agent?.cancel()
        s?.deleteFile()
        live[id] = nil
        index.removeAll { $0.id == id }
        changed()
    }

    func search(_ query: String) -> [SessionIndexEntry] {
        let q = query.lowercased()
        return index.filter { $0.title.lowercased().contains(q) }.sorted { $0.updatedAt > $1.updatedAt }
    }
}
