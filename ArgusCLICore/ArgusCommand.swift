import ArgumentParser

public struct ArgusCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "argus",
        abstract: "Control the running Argus application.",
        version: "argus 1.17.0",
        subcommands: [WorkspaceCommand.self]
    )

    public init() {}
}
