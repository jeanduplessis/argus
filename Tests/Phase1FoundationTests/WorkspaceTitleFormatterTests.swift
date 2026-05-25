import Foundation

@main
struct WorkspaceTitleFormatterTests {
    static func main() {
        assertEqual(
            WorkspaceTitleFormatter.title(workspaceTitle: "argus", contextName: "argus"),
            "argus",
            "redundant workspace/context text is omitted"
        )
        assertEqual(
            WorkspaceTitleFormatter.title(workspaceTitle: "feature-ui", contextName: "Argus"),
            "feature-ui — Argus",
            "distinct workspace/context text is combined"
        )
        assertEqual(
            WorkspaceTitleFormatter.title(workspaceTitle: "", contextName: ""),
            "Argus",
            "empty title context falls back to Argus"
        )
    }

    private static func assertEqual(_ actual: String, _ expected: String, _ message: String) {
        guard actual == expected else {
            fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
            exit(1)
        }
    }
}
