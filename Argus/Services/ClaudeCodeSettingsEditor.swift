import Foundation

/// Edits only Argus's hook entries in a Claude Code `settings.json`.
///
/// Claude Code settings are strict JSON that Claude Code itself rewrites with
/// two-space indentation, so the editor keeps every key in its original order
/// and every number in its original spelling, and writes the same layout back.
enum ClaudeCodeSettingsEditor {
    enum Error: LocalizedError, Equatable {
        case malformed(String)
        case unexpectedShape(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let detail): "Invalid JSON: \(detail)"
            case .unexpectedShape(let detail): "Unexpected Claude Code settings: \(detail)"
            }
        }
    }

    /// One Argus-owned matcher group.
    struct ManagedHook: Equatable {
        let event: String
        let matcher: String?
        let isAsync: Bool
        let timeoutSeconds: Int
    }

    /// Exec'ing the CLI makes Claude Code its parent process, which is how the
    /// CLI identifies the reporting session. Outside an Argus terminal, or
    /// without the bundled CLI on `PATH`, the hook exits silently.
    static let hookCommand =
        #"[ -n "$ARGUS_SURFACE_ID" ] && command -v argus >/dev/null 2>&1 && "#
        + #"exec argus agent claude-code-hook >/dev/null 2>&1; exit 0"#

    // Exact hook commands written by previous Argus releases.
    static let historicalHookCommands: Set<String> = []

    /// Status-only events run asynchronously so they never delay Claude Code.
    /// Turn-ending events run synchronously so delivery finishes before
    /// `claude -p` exits, bounded by the CLI's own one-second deadline.
    static let managedHooks: [ManagedHook] = [
        ManagedHook(event: "SessionStart", matcher: nil, isAsync: false, timeoutSeconds: 5),
        ManagedHook(event: "UserPromptSubmit", matcher: nil, isAsync: true, timeoutSeconds: 5),
        ManagedHook(event: "PreToolUse", matcher: "AskUserQuestion|ExitPlanMode", isAsync: true, timeoutSeconds: 5),
        ManagedHook(event: "PermissionRequest", matcher: nil, isAsync: true, timeoutSeconds: 5),
        ManagedHook(event: "PostToolUse", matcher: nil, isAsync: true, timeoutSeconds: 5),
        ManagedHook(event: "PostToolUseFailure", matcher: nil, isAsync: true, timeoutSeconds: 5),
        ManagedHook(event: "Notification", matcher: nil, isAsync: true, timeoutSeconds: 5),
        ManagedHook(event: "Stop", matcher: nil, isAsync: false, timeoutSeconds: 5),
        ManagedHook(event: "StopFailure", matcher: nil, isAsync: false, timeoutSeconds: 5),
        ManagedHook(event: "SessionEnd", matcher: nil, isAsync: false, timeoutSeconds: 5)
    ]

    enum Operation { case enable, disable }

    static func edit(_ text: String, operation: Operation) throws -> String {
        var root = try parseSettings(text)
        root = try removingArgusHooks(from: root)
        if operation == .enable {
            root = try addingArgusHooks(to: root)
        }
        let trailingNewline = text.isEmpty || text.hasSuffix("\n")
        return root.serialized() + (trailingNewline ? "\n" : "")
    }

    /// True when exactly the current Argus hook set is present.
    static func isInstalled(in text: String) -> Bool {
        guard let root = try? parseSettings(text),
            case .object(let members) = root,
            let hooks = members.value(for: "hooks"),
            case .object(let events) = hooks
        else { return false }
        var installed: [JSONValue] = []
        for member in events {
            guard case .array(let groups) = member.value else { continue }
            installed += groups.filter(containsArgusHandler).map { tagged($0, event: member.key) }
        }
        let expected = managedHooks.map { tagged(group(for: $0), event: $0.event) }
        return installed.count == expected.count && expected.allSatisfy(installed.contains)
    }

    // MARK: - Hook editing

    private static func parseSettings(_ text: String) throws -> JSONValue {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .object([]) }
        let root = try JSONValue.parse(text)
        guard case .object = root else { throw Error.unexpectedShape("the root must be an object") }
        return root
    }

    private static func removingArgusHooks(from root: JSONValue) throws -> JSONValue {
        guard case .object(var members) = root, let hooks = members.value(for: "hooks") else { return root }
        guard case .object(var events) = hooks else { throw Error.unexpectedShape("hooks must be an object") }
        let hadEvents = !events.isEmpty
        events = events.compactMap { member in
            guard case .array(let groups) = member.value, !groups.isEmpty else { return member }
            let remaining = groups.compactMap(removingArgusHandlers)
            return remaining.isEmpty ? nil : JSONValue.Member(key: member.key, value: .array(remaining))
        }
        if hadEvents, events.isEmpty {
            members.removeAll { $0.key == "hooks" }
        } else {
            members.set(.object(events), for: "hooks")
        }
        return .object(members)
    }

    /// The group without Argus handlers, or nil when only Argus handlers remained.
    private static func removingArgusHandlers(from group: JSONValue) -> JSONValue? {
        guard case .object(var members) = group,
            let handlers = members.value(for: "hooks"),
            case .array(let entries) = handlers,
            entries.contains(where: isArgusHandler)
        else { return group }
        let remaining = entries.filter { !isArgusHandler($0) }
        guard !remaining.isEmpty else { return nil }
        members.set(.array(remaining), for: "hooks")
        return .object(members)
    }

    private static func addingArgusHooks(to root: JSONValue) throws -> JSONValue {
        guard case .object(var members) = root else { return root }
        var events: [JSONValue.Member] = []
        if let hooks = members.value(for: "hooks") {
            guard case .object(let existing) = hooks else { throw Error.unexpectedShape("hooks must be an object") }
            events = existing
        }
        for hook in managedHooks {
            var groups: [JSONValue] = []
            if let existing = events.value(for: hook.event) {
                guard case .array(let existingGroups) = existing else {
                    throw Error.unexpectedShape("hooks.\(hook.event) must be an array")
                }
                groups = existingGroups
            }
            events.set(.array(groups + [group(for: hook)]), for: hook.event)
        }
        members.set(.object(events), for: "hooks")
        return .object(members)
    }

    private static func group(for hook: ManagedHook) -> JSONValue {
        var handler: [JSONValue.Member] = [
            .init(key: "type", value: .string("command")),
            .init(key: "command", value: .string(hookCommand))
        ]
        if hook.isAsync {
            handler.append(.init(key: "async", value: .bool(true)))
        }
        handler.append(.init(key: "timeout", value: .number(String(hook.timeoutSeconds))))
        var group: [JSONValue.Member] = []
        if let matcher = hook.matcher {
            group.append(.init(key: "matcher", value: .string(matcher)))
        }
        group.append(.init(key: "hooks", value: .array([.object(handler)])))
        return .object(group)
    }

    private static func tagged(_ group: JSONValue, event: String) -> JSONValue {
        .array([.string(event), group])
    }

    private static func containsArgusHandler(_ group: JSONValue) -> Bool {
        guard case .object(let members) = group,
            let handlers = members.value(for: "hooks"),
            case .array(let entries) = handlers
        else { return false }
        return entries.contains(where: isArgusHandler)
    }

    private static func isArgusHandler(_ handler: JSONValue) -> Bool {
        guard case .object(let members) = handler,
            let command = members.value(for: "command"),
            case .string(let text) = command
        else { return false }
        return text == hookCommand || historicalHookCommands.contains(text)
    }
}

// MARK: - Order-preserving JSON

/// A JSON value that remembers object key order and number spelling.
indirect enum JSONValue: Equatable {
    struct Member: Equatable {
        let key: String
        let value: JSONValue
    }

    case object([Member])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    static func parse(_ text: String) throws -> JSONValue {
        var parser = StrictJSONParser(bytes: Array(text.utf8))
        return try parser.parseDocument()
    }

    /// Two-space layout matching `JSON.stringify(value, null, 2)`.
    func serialized(indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            let lines = members.map { "\(inner)\(Self.quoted($0.key)): \($0.value.serialized(indent: inner))" }
            return "{\n" + lines.joined(separator: ",\n") + "\n\(indent)}"
        case .array(let elements):
            guard !elements.isEmpty else { return "[]" }
            let lines = elements.map { inner + $0.serialized(indent: inner) }
            return "[\n" + lines.joined(separator: ",\n") + "\n\(indent)]"
        case .string(let value): return Self.quoted(value)
        case .number(let raw): return raw
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case let control where control.value < 0x20:
                result += String(format: "\\u%04x", control.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

extension [JSONValue.Member] {
    func value(for key: String) -> JSONValue? {
        first { $0.key == key }?.value
    }

    /// Replaces the value in place, or appends a new member at the end.
    mutating func set(_ value: JSONValue, for key: String) {
        if let index = firstIndex(where: { $0.key == key }) {
            self[index] = JSONValue.Member(key: key, value: value)
        } else {
            append(JSONValue.Member(key: key, value: value))
        }
    }
}

private struct StrictJSONParser {
    typealias Error = ClaudeCodeSettingsEditor.Error

    let bytes: [UInt8]
    var position = 0

    mutating func parseDocument() throws -> JSONValue {
        let value = try parseValue()
        skipWhitespace()
        guard position == bytes.count else { throw Error.malformed("unexpected content at byte \(position)") }
        return value
    }

    private mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard let byte = peek() else { throw Error.malformed("unexpected end of file") }
        switch byte {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): return try parseLiteral("true", .bool(true))
        case UInt8(ascii: "f"): return try parseLiteral("false", .bool(false))
        case UInt8(ascii: "n"): return try parseLiteral("null", .null)
        default: return try parseNumber()
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        position += 1
        var members: [JSONValue.Member] = []
        skipWhitespace()
        if consume(UInt8(ascii: "}")) { return .object(members) }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else { throw Error.malformed("object key expected at byte \(position)") }
            let key = try parseString()
            skipWhitespace()
            guard consume(UInt8(ascii: ":")) else { throw Error.malformed("colon expected at byte \(position)") }
            members.append(JSONValue.Member(key: key, value: try parseValue()))
            skipWhitespace()
            if consume(UInt8(ascii: "}")) { return .object(members) }
            guard consume(UInt8(ascii: ",")) else { throw Error.malformed("comma expected at byte \(position)") }
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        position += 1
        var elements: [JSONValue] = []
        skipWhitespace()
        if consume(UInt8(ascii: "]")) { return .array(elements) }
        while true {
            elements.append(try parseValue())
            skipWhitespace()
            if consume(UInt8(ascii: "]")) { return .array(elements) }
            guard consume(UInt8(ascii: ",")) else { throw Error.malformed("comma expected at byte \(position)") }
        }
    }

    private mutating func parseString() throws -> String {
        let start = position
        position += 1
        while let byte = peek() {
            switch byte {
            case UInt8(ascii: "\""):
                position += 1
                // Foundation decodes escapes and validates UTF-8 for the literal.
                let literal = Data(bytes[start..<position])
                guard let value = try? JSONDecoder().decode(String.self, from: literal) else {
                    throw Error.malformed("invalid string at byte \(start)")
                }
                return value
            case UInt8(ascii: "\\"):
                position += 2
            case 0..<0x20:
                throw Error.malformed("unescaped control character at byte \(position)")
            default:
                position += 1
            }
        }
        throw Error.malformed("unterminated string at byte \(start)")
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = position
        while let byte = peek(), "+-0123456789.eE".utf8.contains(byte) { position += 1 }
        let raw = String(bytes: bytes[start..<position], encoding: .utf8) ?? ""
        guard !raw.isEmpty, (try? JSONDecoder().decode(Double.self, from: Data(raw.utf8))) != nil else {
            throw Error.malformed("invalid value at byte \(start)")
        }
        return .number(raw)
    }

    private mutating func parseLiteral(_ literal: String, _ value: JSONValue) throws -> JSONValue {
        let expected = Array(literal.utf8)
        guard bytes.count - position >= expected.count,
            Array(bytes[position..<position + expected.count]) == expected
        else { throw Error.malformed("invalid value at byte \(position)") }
        position += expected.count
        return value
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), [0x20, 0x09, 0x0A, 0x0D].contains(byte) { position += 1 }
    }

    private func peek() -> UInt8? {
        position < bytes.count ? bytes[position] : nil
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard peek() == byte else { return false }
        position += 1
        return true
    }
}
