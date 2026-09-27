import Foundation

/// One content block of a Messages-API conversation turn.
enum ContentBlock: Codable, Equatable {
    case text(String)
    case thinking(text: String, signature: String?)
    case toolUse(id: String, name: String, input: String)
    case toolResult(id: String, content: String, isError: Bool, images: [ImageData]?)
    case image(ImageData)

    struct ImageData: Codable, Equatable {
        var mediaType: String
        var base64: String
        var path: String?
    }

    private enum K: String, CodingKey { case type, text, signature, id, name, input, content, isError, images, image }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "thinking": self = .thinking(text: try c.decode(String.self, forKey: .text), signature: try c.decodeIfPresent(String.self, forKey: .signature))
        case "tool_use": self = .toolUse(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name), input: try c.decode(String.self, forKey: .input))
        case "tool_result": self = .toolResult(id: try c.decode(String.self, forKey: .id), content: try c.decode(String.self, forKey: .content),
                                              isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false,
                                              images: try c.decodeIfPresent([ImageData].self, forKey: .images))
        case "image": self = .image(try c.decode(ImageData.self, forKey: .image))
        default: self = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .text(let t): try c.encode("text", forKey: .type); try c.encode(t, forKey: .text)
        case .thinking(let t, let s): try c.encode("thinking", forKey: .type); try c.encode(t, forKey: .text); try c.encodeIfPresent(s, forKey: .signature)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(input, forKey: .input)
        case .toolResult(let id, let content, let isError, let images):
            try c.encode("tool_result", forKey: .type); try c.encode(id, forKey: .id); try c.encode(content, forKey: .content)
            if isError { try c.encode(true, forKey: .isError) }
            try c.encodeIfPresent(images, forKey: .images)
        case .image(let img): try c.encode("image", forKey: .type); try c.encode(img, forKey: .image)
        }
    }

    /// Wire form for the Messages API.
    var wire: JSON {
        switch self {
        case .text(let t): return ["type": "text", "text": .string(t)]
        case .thinking(let t, let s):
            var o: [String: JSON] = ["type": "thinking", "thinking": .string(t)]
            if let s, !s.isEmpty { o["signature"] = .string(s) }
            return .object(o)
        case .toolUse(let id, let name, let input):
            var parsed = JSON.parse(input) ?? .object([:])
            if parsed.object == nil { parsed = .object([:]) }
            return ["type": "tool_use", "id": .string(id), "name": .string(name), "input": parsed]
        case .toolResult(let id, let content, let isError, let images):
            var parts: [JSON] = []
            if !content.isEmpty { parts.append(["type": "text", "text": .string(content)]) }
            for img in images ?? [] {
                parts.append(["type": "image", "source": ["type": "base64", "media_type": .string(img.mediaType), "data": .string(img.base64)]])
            }
            var o: [String: JSON] = ["type": "tool_result", "tool_use_id": .string(id), "content": .array(parts)]
            if isError { o["is_error"] = true }
            return .object(o)
        case .image(let img):
            return ["type": "image", "source": ["type": "base64", "media_type": .string(img.mediaType), "data": .string(img.base64)]]
        }
    }
}

struct Usage: Codable, Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var promptTotal: Int { input + cacheRead + cacheWrite }
    var total: Int { promptTotal + output }
    static func + (a: Usage, b: Usage) -> Usage {
        Usage(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
}

enum Role: String, Codable { case user, assistant }

struct Message: Codable, Equatable {
    var id: String = UUID().uuidString
    var role: Role
    var blocks: [ContentBlock]
    var time: Double = Date().timeIntervalSince1970
    /// Assistant only: token usage and generation duration of this step.
    var usage: Usage?
    var model: String?
    var duration: Double?
    /// User only: true when this message only carries tool results (not a human-authored turn start).
    var isToolResults: Bool?
    /// User only: text typed while the agent was running and spliced into the loop.
    var steered: Bool?
    /// User only: harness-generated notice (e.g. background job finished), rendered compactly.
    var notice: Bool?

    var text: String {
        blocks.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "\n\n")
    }

    var wire: JSON {
        ["role": .string(role.rawValue), "content": .array(blocks.map { $0.wire })]
    }
}

struct TodoItem: Codable, Equatable {
    var content: String
    var status: String // pending | in_progress | completed
}

enum ToolStatus: String, Codable { case pending, running, awaitingApproval, done, error, denied, cancelled }

/// Runtime state of one tool call, keyed by call id.
struct ToolRun: Codable, Equatable {
    var status: ToolStatus
    var startedAt: Double?
    var finishedAt: Double?
    var output: String?
    var progress: String?
    var meta: JSON?
}

enum TurnEnd: Codable, Equatable {
    case completed
    case stopped
    case error(String)
}

struct TurnRecord: Codable, Equatable {
    var index: Int
    var startedAt: Double
    var endedAt: Double?
    var end: TurnEnd?
    /// Index into `messages` of the human message that started the turn.
    var messageIndex: Int
}
