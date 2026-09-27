import Foundation

enum Paths {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DeepSeek Native", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let sessions: URL = sub("sessions")
    static let spill: URL = sub("spill")
    static let settingsFile = appSupport.appendingPathComponent("settings.json")
    static let workspacesFile = appSupport.appendingPathComponent("workspaces.json")

    private static func sub(_ name: String) -> URL {
        let d = appSupport.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

enum ReasoningEffort: String, Codable, CaseIterable {
    case off, low, high, max
    var label: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .high: return "High"
        case .max: return "Max"
        }
    }
}

enum PermissionMode: String, Codable, CaseIterable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case fullAccess = "danger-full-access"
    var label: String {
        switch self {
        case .readOnly: return "Read Only"
        case .workspaceWrite: return "Workspace Write"
        case .fullAccess: return "Full Access"
        }
    }
    var symbol: String {
        switch self {
        case .readOnly: return "lock.shield"
        case .workspaceWrite: return "checkmark.shield"
        case .fullAccess: return "exclamationmark.shield"
        }
    }
    var detail: String {
        switch self {
        case .readOnly: return "Commands can read files; any write asks first."
        case .workspaceWrite: return "Edits inside the workspace run freely; outside writes ask first."
        case .fullAccess: return "No sandbox and no approvals. Use with care."
        }
    }
}

enum Appearance: String, Codable, CaseIterable {
    case system, light, dark
}

struct ModelInfo {
    let id: String
    let name: String
    let detail: String
    static let all: [ModelInfo] = [
        ModelInfo(id: "deepseek-flash", name: "DeepSeek-V41-Flash", detail: "Fast, capable default for everyday agentic work."),
        ModelInfo(id: "deepseek-v4-pro", name: "DeepSeek-V4-Pro", detail: "Stronger agentic coding, knowledge, and difficult reasoning; suited to complex or quality-critical tasks at higher cost."),
    ]
    static func name(for id: String) -> String { all.first { $0.id == id }?.name ?? id }
}

/// User settings persisted as JSON with owner-only permissions.
final class Settings: Codable {
    static let shared: Settings = Settings.load()
    static let didChange = Notification.Name("SettingsDidChange")

    var apiKey: String = ""
    var baseURL: String = "https://api.deepseek.com/anthropic"
    var model: String = "deepseek-flash"
    var effort: ReasoningEffort = .high
    var maxTokens: Int = 256_000
    var contextWindow: Int = 1_000_000
    var appearance: Appearance = .system
    var permissionMode: PermissionMode = .workspaceWrite
    var bashTimeoutMs: Int = 120_000
    var webSearchEnabled: Bool = true
    var subagentsEnabled: Bool = true
    var sendOnEnter: Bool = true
    var customInstructions: String = ""

    enum CodingKeys: String, CodingKey {
        case apiKey, baseURL, model, effort, maxTokens, contextWindow, appearance, permissionMode, bashTimeoutMs,
             webSearchEnabled, subagentsEnabled, sendOnEnter, customInstructions
    }

    init() {}

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil ?? d }
        apiKey = v(.apiKey, "")
        baseURL = v(.baseURL, baseURL)
        model = v(.model, model)
        effort = v(.effort, effort)
        maxTokens = v(.maxTokens, maxTokens)
        contextWindow = v(.contextWindow, contextWindow)
        appearance = v(.appearance, appearance)
        permissionMode = v(.permissionMode, permissionMode)
        bashTimeoutMs = v(.bashTimeoutMs, bashTimeoutMs)
        webSearchEnabled = v(.webSearchEnabled, webSearchEnabled)
        subagentsEnabled = v(.subagentsEnabled, subagentsEnabled)
        sendOnEnter = v(.sendOnEnter, sendOnEnter)
        customInstructions = v(.customInstructions, customInstructions)
    }

    private static func load() -> Settings {
        let s: Settings
        if let data = try? Data(contentsOf: Paths.settingsFile), let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            s = decoded
        } else {
            s = Settings()
        }
        if s.apiKey.isEmpty {
            s.apiKey = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] ?? Settings.importHarnessKey() ?? ""
            if !s.apiKey.isEmpty { s.save(notify: false) }
        }
        if let base = ProcessInfo.processInfo.environment["DEEPSEEK_BASE_URL"], !base.isEmpty { s.baseURL = base }
        if let w = ProcessInfo.processInfo.environment["DSN_CONTEXT_WINDOW"].flatMap(Int.init) { s.contextWindow = w }
        return s
    }

    /// Reads `DEEPSEEK_API_KEY` from the DeepSeek Harness credential file (~/.dsh/.credentials.yaml).
    static func importHarnessKey() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/.credentials.yaml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("DEEPSEEK_API_KEY:") {
                var v = t.dropFirst("DEEPSEEK_API_KEY:".count).trimmingCharacters(in: .whitespaces)
                v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    func save(notify: Bool = true) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Paths.settingsFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.settingsFile.path)
        }
        if notify { NotificationCenter.default.post(name: Settings.didChange, object: nil) }
    }

    var messagesEndpoint: URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/v1") { base += "/v1" }
        return URL(string: base + "/messages") ?? URL(string: "https://api.deepseek.com/anthropic/v1/messages")!
    }
}
