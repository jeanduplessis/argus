import Foundation

struct EmptyResponse: Decodable {}

extension GitHubCLIProvider {
    func githubDisposition(_ disposition: ReviewDisposition) -> String {
        switch disposition {
        case .approve:
            "APPROVE"
        case .comment:
            "COMMENT"
        case .requestChanges:
            "REQUEST_CHANGES"
        }
    }

    func graphql(mutation: String, variables: [String: String], host: String) async throws -> EmptyResponse {
        try await graphqlJSON(query: mutation, variables: variables, host: host)
    }

    func allRESTPages<Response: Decodable>(endpoint: String, host: String) async throws -> [Response] {
        var values: [Response] = []
        var page = 1
        while true {
            let response: [Response] = try await apiJSON(
                ["\(endpoint)?per_page=100&page=\(page)"],
                host: host
            )
            values += response
            guard response.count == 100 else { return values }
            page += 1
        }
    }

    func chronologicalActivity(_ activity: [GitHubPullRequestActivity]) -> [GitHubPullRequestActivity] {
        var seenIDs = Set<String>()
        let unique = activity.enumerated().filter { seenIDs.insert($0.element.id).inserted }
        return unique.sorted {
            $0.element.createdAt == $1.element.createdAt
                ? $0.offset < $1.offset
                : $0.element.createdAt < $1.element.createdAt
        }.map(\.element)
    }

    func graphqlJSON<Response: Decodable>(query: String, variables: [String: Any], host: String) async throws -> Response {
        let payload: [String: Any] = [
            "query": query,
            "variables": variables
        ]
        let standardInput = try JSONSerialization.data(withJSONObject: payload)
        return try await apiJSON(
            ["graphql", "--method", "POST"],
            host: host,
            standardInput: standardInput
        )
    }

    func apiJSON<Response: Decodable>(_ endpoint: [String], host: String, standardInput: Data? = nil) async throws -> Response {
        guard let host = Self.canonicalHost(host) else {
            throw GitHubCLIProviderError.validation("GitHub host is invalid")
        }
        var arguments = ["api", "--hostname", host] + endpoint
        if standardInput != nil {
            arguments += ["--input", "-"]
        }
        let request = CommandRequest(
            executableURL: executableURL,
            arguments: arguments,
            standardInput: standardInput,
            environment: noninteractiveEnvironment(),
            timeout: timeout
        )
        do {
            let result = try await runner.run(request)
            do {
                return try decoder.decode(Response.self, from: result.standardOutput)
            } catch {
                throw GitHubCLIProviderError.malformedResponse(
                    "GitHub returned invalid JSON: \(sanitizedDiagnostic(error.localizedDescription))"
                )
            }
        } catch let error as GitHubCLIProviderError {
            throw error
        } catch let error as CommandRunnerError {
            throw classify(error, host: host)
        } catch is CancellationError {
            throw GitHubCLIProviderError.cancelled
        } catch {
            throw GitHubCLIProviderError.commandFailed(sanitizedDiagnostic(error.localizedDescription))
        }
    }

    func noninteractiveEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let configurationKeys = ["HOME", "GH_CONFIG_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"]
        var environment = Dictionary(uniqueKeysWithValues: configurationKeys.compactMap { key in
            inherited[key].map { (key, $0) }
        })
        environment.merge([
            // `gh` may invoke git for a small number of read paths. Keep a fixed
            // system path without using it to select the `gh` executable itself.
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GH_PROMPT_DISABLED": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "GH_NO_UPDATE_NOTIFIER": "1"
        ]) { _, newValue in newValue }
        return environment
    }

    static func trustedExecutableURL() -> URL {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        let selected = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
        return URL(fileURLWithPath: selected)
    }

    func classify(_ error: CommandRunnerError, host: String) -> GitHubCLIProviderError {
        switch error {
        case .launchFailed:
            return .cliUnavailable
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        case .nonZeroExit(let result):
            let detail = sanitizedDiagnostic(result.standardErrorString)
            let lowercased = detail.lowercased()
            if lowercased.contains("gh: no such file") || lowercased.contains("gh: command not found") { return .cliUnavailable }
            if lowercased.contains("not logged in") || lowercased.contains("authentication required") { return .unauthenticated(host: host) }
            if lowercased.contains("rate limit") { return .rateLimited(detail) }
            if lowercased.contains("not found") || lowercased.contains("404") { return .notFound(detail) }
            if lowercased.contains("forbidden") || lowercased.contains("401") || lowercased.contains("403") { return .authorization(detail) }
            if lowercased.contains("network") || lowercased.contains("connection") || lowercased.contains("timeout") { return .network(detail) }
            if lowercased.contains("validation") || lowercased.contains("unprocessable") { return .validation(detail) }
            return .commandFailed(detail.isEmpty ? "GitHub CLI exited with status \(result.terminationStatus)" : detail)
        }
    }

    func validate(_ identity: PullRequestIdentity) throws {
        guard valid(identity) else {
            throw GitHubCLIProviderError.validation("Pull Request identity is invalid")
        }
    }

    func valid(_ identity: PullRequestIdentity) -> Bool {
        identity.isValid && valid(identity.repository)
    }

    func valid(_ repository: RepositoryIdentity) -> Bool {
        repository.provider == "github"
            && Self.canonicalHost(repository.host) != nil
            && Self.validRepositorySegment(repository.owner)
            && Self.validRepositorySegment(repository.name)
    }

    func valid(_ revision: ReviewRevision) -> Bool {
        revision.isValid
    }

    func validCommit(_ commit: String) -> Bool {
        ReviewRevision.isProviderSafeCommit(commit)
    }

    func validFilePath(_ path: String) -> Bool {
        !path.isEmpty
            && path.utf8.count <= 4_096
            && !path.hasPrefix("/")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains { component in
                component.isEmpty
                    || component == "."
                    || component == ".."
                    || component.contains("\\")
                    || component.unicodeScalars.contains(where: { $0.value == 0 })
            }
    }

    func validNodeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && value.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7e }
    }

    func pullRequestEndpoint(_ identity: PullRequestIdentity) -> String {
        "repos/\(Self.apiPathSegment(identity.repository.owner))/\(Self.apiPathSegment(identity.repository.name))/pulls/\(identity.number)"
    }

    static func canonicalHost(_ value: String?) -> String? {
        guard let value else { return nil }
        let host = value.lowercased()
        guard host.utf8.count <= 253,
              !host.isEmpty,
              !host.hasPrefix("."),
              !host.hasSuffix("."),
              host.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
              }),
              !host.contains("..")
        else {
            return nil
        }
        return host
    }

    static func validRepositorySegment(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 100 && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." }
    }

    static func apiPathSegment(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    func sanitizedDiagnostic(_ detail: String) -> String {
        let bounded = String(detail.prefix(2_048))
        let patterns: [(String, String)] = [
            (#"(?i)(authorization\s*[:=]\s*)[^\r\n]+"#, "$1[redacted]"),
            (#"(?i)(\b(?:token|bearer|gh_token|github_token)\s*[:= ]\s*)[^\s,;]+"#, "$1[redacted]"),
            (#"(?i)(?:/Users/[^\s:]+|/home/[^\s:]+|~/.config/[^\s:]+)"#, "[redacted]")
        ]
        return patterns.reduce(bounded) { text, pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern.0) else { return text }
            return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: pattern.1)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
