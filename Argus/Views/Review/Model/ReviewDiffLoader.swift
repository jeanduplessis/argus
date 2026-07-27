import Foundation

@MainActor
struct ReviewDiffLoader {
    struct Request {
        let file: ReviewChangedFile
        let tabID: UUID
        let pullRequest: PullRequestIdentity
        let revision: ReviewRevision
        let theme: ArgusDiffTheme
    }

    private let provider: any ReviewProviding

    init(provider: any ReviewProviding) {
        self.provider = provider
    }

    func load(
        _ request: Request,
        isCurrent: @MainActor (UUID, PullRequestIdentity, ReviewRevision, String) -> Bool
    ) async throws -> ArgusDiffInput {
        let file = request.file
        guard file.contentState == .available, file.status != .binary else {
            throw GitHubCLIProviderError.validation("This file cannot be rendered as text")
        }

        async let oldData = file.status == .added
            ? Data()
            : provider.fileContent(
                path: file.previousPath ?? file.path,
                at: request.revision.baseCommit,
                in: request.pullRequest.repository
            )
        async let newData = file.status == .deleted
            ? Data()
            : provider.fileContent(
                path: file.path,
                at: request.revision.headCommit,
                in: request.pullRequest.repository
            )
        let (old, new) = try await (oldData, newData)

        guard isText(old), isText(new) else {
            throw GitHubCLIProviderError.validation("GitHub returned binary content; it is not decoded as text")
        }
        guard old.count <= 4_000_000, new.count <= 4_000_000 else {
            throw GitHubCLIProviderError.validation("This diff is too large to render")
        }
        guard isCurrent(request.tabID, request.pullRequest, request.revision, file.path) else {
            throw CancellationError()
        }

        return .init(
            oldFile: .init(name: file.previousPath ?? file.path, contents: String(decoding: old, as: UTF8.self)),
            newFile: .init(name: file.path, contents: String(decoding: new, as: UTF8.self)),
            options: .init(theme: request.theme, style: .split, overflow: .scroll)
        )
    }

    private func isText(_ data: Data) -> Bool {
        !data.contains(0) && String(data: data, encoding: .utf8) != nil
    }
}
