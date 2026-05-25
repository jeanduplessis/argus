import Foundation

@main
struct GitStatusRootResolverTests {
    static func main() {
        resolvesWorktreeRootWithoutTerminalDirectory()
        resolvesMainCheckoutToProjectRepositoryRoot()
        resolvesStandaloneToWorkspaceDirectory()
    }

    private static func resolvesWorktreeRootWithoutTerminalDirectory() {
        let context = GitStatusRootContext(
            kind: .worktree,
            currentDirectory: "/tmp/repo/subdir/from-shell",
            worktreePath: "/tmp/worktree-root",
            projectRepositoryPath: "/tmp/main-repo"
        )

        assertEqual(GitStatusRootResolver().root(for: context), "/tmp/worktree-root", "worktree root wins over shell cwd")
    }

    private static func resolvesMainCheckoutToProjectRepositoryRoot() {
        let context = GitStatusRootContext(
            kind: .mainCheckout,
            currentDirectory: "/tmp/repo/subdir/from-shell",
            worktreePath: nil,
            projectRepositoryPath: "/tmp/main-repo"
        )

        assertEqual(GitStatusRootResolver().root(for: context), "/tmp/main-repo", "project repository root wins for main checkout")
    }

    private static func resolvesStandaloneToWorkspaceDirectory() {
        let context = GitStatusRootContext(
            kind: .standalone,
            currentDirectory: "/tmp/standalone",
            worktreePath: nil,
            projectRepositoryPath: nil
        )

        assertEqual(GitStatusRootResolver().root(for: context), "/tmp/standalone", "standalone uses workspace directory")
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        guard actual == expected else {
            fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
            exit(1)
        }
    }
}
