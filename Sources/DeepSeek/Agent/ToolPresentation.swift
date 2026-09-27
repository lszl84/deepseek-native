import Foundation

/// Human-facing labels for tool calls, shared by the transcript and subagent progress lines.
enum ToolPresentation {
    enum Category: Int { case command, read, edit, write, search, plan, web, delegate, ask, other }

    static func category(_ name: String) -> Category {
        switch name {
        case "bash", "job_output", "job_kill", "job_list": return .command
        case "read", "read_image": return .read
        case "edit": return .edit
        case "write": return .write
        case "grep", "glob": return .search
        case "todo_write": return .plan
        case "web_fetch", "web_search": return .web
        case "subagent": return .delegate
        case "ask_user_question": return .ask
        default: return .other
        }
    }

    static func displayName(_ name: String) -> String {
        switch name {
        case "bash": return "Bash"
        case "read": return "Read"
        case "read_image": return "View image"
        case "edit": return "Edit"
        case "write": return "Write"
        case "grep": return "Grep"
        case "glob": return "Glob"
        case "todo_write": return "Update to-do list"
        case "web_fetch": return "Fetch"
        case "web_search": return "Web search"
        case "subagent": return "Subagent"
        case "ask_user_question": return "Ask user"
        case "present": return "Present files"
        case "job_output": return "Job output"
        case "job_kill": return "Stop job"
        case "job_list": return "List jobs"
        default: return name
        }
    }

    static func symbol(_ name: String) -> String {
        switch name {
        case "bash": return "chevron.forward.dotted.chevron.forward"
        case "read": return "doc.text"
        case "read_image": return "photo"
        case "edit": return "pencil.line"
        case "write": return "square.and.pencil"
        case "grep": return "text.magnifyingglass"
        case "glob": return "folder.badge.questionmark"
        case "todo_write": return "checklist"
        case "web_fetch": return "globe"
        case "web_search": return "magnifyingglass"
        case "subagent": return "person.2"
        case "ask_user_question": return "questionmark.bubble"
        case "present": return "doc.richtext"
        case "job_output", "job_list": return "tray.full"
        case "job_kill": return "stop.circle"
        default: return "wrench.and.screwdriver"
        }
    }

    static func shortPath(_ p: String, cwd: String?) -> String {
        if let cwd, p.hasPrefix(cwd + "/") { return String(p.dropFirst(cwd.count + 1)) }
        let home = NSHomeDirectory()
        if p.hasPrefix(home) { return "~" + p.dropFirst(home.count) }
        return p
    }

    /// One-line summary shown after the tool's name.
    static func summary(name: String, input: JSON, cwd: String?) -> String {
        switch name {
        case "bash": return input["description"]?.string ?? input["command"]?.string ?? ""
        case "read", "write", "edit", "read_image": return shortPath(input["file_path"]?.string ?? "", cwd: cwd)
        case "grep":
            var s = input["pattern"]?.string ?? ""
            if let p = input["path"]?.string { s += " in " + shortPath(p, cwd: cwd) }
            if let i = input["include"]?.string { s += " (\(i))" }
            return s
        case "glob": return input["pattern"]?.string ?? ""
        case "todo_write":
            guard let todos = input["todos"]?.array, !todos.isEmpty else { return "" }
            let done = todos.filter { $0["status"]?.string == "completed" }.count
            let current = todos.first { $0["status"]?.string == "in_progress" }?["content"]?.string
            return "\(done)/\(todos.count) completed" + (current.map { " · " + $0 } ?? "")
        case "web_fetch": return input["url"]?.string ?? ""
        case "web_search": return (input["queries"]?.array?.compactMap { $0.string } ?? []).joined(separator: " · ")
        case "subagent": return input["description"]?.string ?? ""
        case "ask_user_question": return input["questions"]?.array?.first?["question"]?.string ?? ""
        case "present": return (input["files"]?.array?.compactMap { $0["path"]?.string.map { ($0 as NSString).lastPathComponent } } ?? []).joined(separator: ", ")
        case "job_output", "job_kill": return input["job_id"]?.string ?? ""
        default: return ""
        }
    }

    static func activityLine(name: String, input: JSON) -> String {
        let s = summary(name: name, input: input, cwd: nil)
        return s.isEmpty ? displayName(name) : displayName(name) + " · " + s
    }

    /// Group heading for a run of tool calls, e.g. "Ran commands", "Wrote files and ran commands".
    static func groupTitle(categories: [Category], running: Bool) -> String {
        var order: [Category] = []
        for c in categories where !order.contains(c) { order.append(c) }
        let phrases: [String] = order.prefix(2).map { c in
            switch c {
            case .command: return running ? "running commands" : "ran commands"
            case .read: return running ? "reading files" : "read files"
            case .edit: return running ? "editing files" : "edited files"
            case .write: return running ? "writing files" : "wrote files"
            case .search: return running ? "searching" : "searched the workspace"
            case .plan: return running ? "updating the plan" : "updated the plan"
            case .web: return running ? "browsing the web" : "browsed the web"
            case .delegate: return running ? "delegating work" : "delegated work"
            case .ask: return running ? "asking a question" : "asked a question"
            case .other: return running ? "using tools" : "used tools"
            }
        }
        var s = phrases.joined(separator: " and ")
        if order.count > 2 { s += running ? ", and more" : " and more" }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func groupSymbol(categories: [Category]) -> String {
        guard let first = categories.first else { return "sparkles" }
        switch first {
        case .command: return "chevron.forward.dotted.chevron.forward"
        case .read: return "doc.text"
        case .edit, .write: return "square.and.pencil"
        case .search: return "magnifyingglass"
        case .plan: return "checklist"
        case .web: return "globe"
        case .delegate: return "person.2"
        case .ask: return "questionmark.bubble"
        case .other: return "wrench.and.screwdriver"
        }
    }
}
