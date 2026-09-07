import Foundation
import Testing

@testable import Argus

extension RecordedBaseBranchReaderTests {
    @Test(arguments: ["sha1", "sha256"])
    func inventoryTracksActualHeadsIndependentlyOfRecordedParents(objectFormat: String) throws {
        let fixture = try RecordedParentRepository(objectFormat: objectFormat)
        let child = try fixture.addWorktree(branch: "child")
        try fixture.git(["config", "branch.child.base", "main"])
        let initialHead = try fixture.git(["rev-parse", "HEAD"])
        let initial = try fixture.read()
        #expect(initial.worktrees.allSatisfy { $0.headCommitID == initialHead })
        try fixture.git(
            [
                "-c", "user.name=Test User", "-c", "user.email=test@example.com",
                "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                "commit", "--allow-empty", "-m", "later child work"
            ], checkout: child)
        let changedHead = try fixture.git(["rev-parse", "HEAD"], checkout: child)

        let changed = try fixture.read()

        #expect(changed.parents == initial.parents)
        #expect(changedHead != initialHead)
        #expect(changed.worktrees.first { $0.path == child.path }?.headCommitID == changedHead)
        #expect(changed.worktrees.first { $0.path == fixture.repository.path }?.headCommitID == initialHead)
        #expect(changed == (try fixture.read(checkout: child)))
        try fixture.git(["switch", "--detach"], checkout: child)
        let detached = try fixture.read()
        #expect(detached.worktrees.first { $0.path == child.path }?.branch == nil)
        #expect(detached.worktrees.first { $0.path == child.path }?.headCommitID == changedHead)
    }

    @Test
    func unbornInventoryHasNoCommitEvidenceAndKeepsRecordedParents() throws {
        let fixture = try RecordedParentRepository()
        try fixture.git(["switch", "--orphan", "unborn"])
        try fixture.git(["config", "branch.unborn.base", "main"])

        let snapshot = try fixture.read()

        #expect(snapshot.parents == ["unborn": "main"])
        #expect(snapshot.worktrees == [GitWorktreeBranch(path: fixture.repository.path, branch: "unborn")])
    }
}
