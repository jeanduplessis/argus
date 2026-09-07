import Combine
import Foundation

extension WorkspacePullRequestStatusModel {
    func evidence(for target: WorkspacePullRequestTarget, at date: Date) -> WorkspacePullRequestEvidence? {
        guard isEnabled, let entry = entries[target.workspaceID], entry.target == target,
            let evidence = entry.evidence, let project = projects[target.projectID],
            let state = states[target.workspaceID], state.error == nil, project.error == nil,
            hostPause(project) == nil, project.resolvedAt != nil,
            evidence.target == target, evidence.repository == project.repository,
            evidence.fetchRemotes == project.fetchRemotes,
            evidence.ownership.workspaceGeneration == entry.owner,
            evidence.ownership.projectGeneration == project.owner,
            evidence.ownership.repositoryGeneration == project.revision,
            evidence.ownership.observationGeneration == entry.observation,
            evidence.branch == entry.branch, evidence.status == state.status,
            evidence.validatedAt == state.lastSuccess,
            evidence.matches(
                target: target, branchName: evidence.branch.branchName,
                headCommitID: evidence.branch.headCommitObjectID, at: date)
        else { return nil }
        return evidence
    }

    func evidence(for workspaceID: UUID, at date: Date) -> WorkspacePullRequestEvidence? {
        guard let target = entries[workspaceID]?.target else { return nil }
        return evidence(for: target, at: date)
    }

    func publishEvidence(_ status: PullRequestStatus?, operation: RunningRequest, validatedAt: Date) {
        let request = operation.request
        let id = request.target.workspaceID
        guard isCurrent(operation), let status, let repository = operation.repository,
            states[id]?.error == nil, projects[request.target.projectID]?.error == nil
        else {
            invalidateEvidence(id)
            return
        }
        let evidence = WorkspacePullRequestEvidence(
            target: request.target, repository: repository, branch: request.branch,
            fetchRemotes: request.fetchRemotes,
            ownership: WorkspacePullRequestEvidence.Ownership(
                workspaceGeneration: request.owner, projectGeneration: request.projectOwner,
                repositoryGeneration: request.revision, observationGeneration: request.observation,
                requestID: operation.id
            ),
            status: status, validatedAt: validatedAt
        )
        objectWillChange.send()
        entries[id]?.evidence = evidence
    }

    func invalidateEvidence(_ workspaceID: UUID) {
        guard entries[workspaceID]?.evidence != nil else { return }
        objectWillChange.send()
        entries[workspaceID]?.evidence = nil
    }

    func invalidateProjectEvidence(_ projectID: UUID) {
        for (id, entry) in entries where entry.target.projectID == projectID {
            invalidateEvidence(id)
        }
    }

    func invalidateHostEvidence(_ host: String) {
        for (id, entry) in entries where entry.evidence?.repository.host == host {
            invalidateEvidence(id)
        }
    }
}
