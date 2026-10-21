import ArgumentParser
import Foundation

/// Agent Integration entry points. Hidden from help: these are run by an
/// agent's own hook configuration, not typed by a person.
struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Report coding-agent lifecycle events to Argus.",
        shouldDisplay: false,
        subcommands: [ClaudeCodeHookCommand.self]
    )
}

struct ClaudeCodeHookCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claude-code-hook",
        abstract: "Translate one Claude Code hook event from stdin into Agent Status.",
        discussion: """
            Installed by Settings > Agent > Claude Code Integration. Prints \
            nothing and always exits 0, so it can never change Claude Code's \
            behavior or add to its context.
            """
    )

    func run() {
        let environment = ProcessInfo.processInfo.environment
        let requests = ClaudeCodeHook.requests(
            input: FileHandle.standardInput.readDataToEndOfFile(),
            environment: environment,
            sessionId: ClaudeCodeHook.parentProcessSessionID(),
            sequence: ClaudeCodeHook.monotonicSequence()
        )
        guard !requests.isEmpty, let socketPath = environment["ARGUS_SOCKET_PATH"] else { return }
        ClaudeCodeHook.deliver(requests, socketPath: socketPath)
    }
}
