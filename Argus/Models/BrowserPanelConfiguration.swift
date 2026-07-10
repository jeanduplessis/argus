import Foundation

struct BrowserPanelConfiguration {
    enum SearchProvider: String, CaseIterable, Identifiable {
        case none
        case duckDuckGo
        case google
        case bing

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: "None"
            case .duckDuckGo: "DuckDuckGo"
            case .google: "Google"
            case .bing: "Bing"
            }
        }
    }

    enum DataStore: String, CaseIterable, Identifiable {
        case persistent
        case `private`

        var id: String { rawValue }

        var title: String { rawValue.capitalized }
    }

    let homepage: String
    let searchProvider: SearchProvider
    let pageZoom: Double
    let developerToolsEnabled: Bool
    let dataStore: DataStore

    static let `default` = BrowserPanelConfiguration(
        homepage: "",
        searchProvider: .none,
        pageZoom: 1,
        developerToolsEnabled: false,
        dataStore: .persistent
    )
}

enum BrowserNavigationPolicy {
    static func resolvedURL(
        from input: String,
        searchProvider: BrowserPanelConfiguration.SearchProvider = .none
    ) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if searchProvider != .none, isQueryLike(trimmed) {
            return searchURL(for: trimmed, provider: searchProvider)
        }

        return directURL(from: trimmed)
    }

    static func directURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()
        let hasExplicitScheme =
            trimmed.contains("://")
            || ["about:", "data:", "file:", "mailto:"].contains(where: lowercased.hasPrefix)
        let candidate = hasExplicitScheme ? trimmed : "https://\(trimmed)"

        if let url = URL(string: candidate) {
            return url
        }
        return candidate.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
            .flatMap(URL.init(string:))
    }

    private static func isQueryLike(_ input: String) -> Bool {
        if input.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return true }
        let lowercased = input.lowercased()
        if input.contains("://") || ["about:", "data:", "file:", "mailto:"].contains(where: lowercased.hasPrefix) {
            return false
        }
        if input == "localhost" || input.hasPrefix("localhost:") || input.contains(".") || input.contains(":") {
            return false
        }
        return true
    }

    private static func searchURL(
        for query: String,
        provider: BrowserPanelConfiguration.SearchProvider
    ) -> URL? {
        let baseURL: String
        switch provider {
        case .none:
            return directURL(from: query)
        case .duckDuckGo:
            baseURL = "https://duckduckgo.com/?q="
        case .google:
            baseURL = "https://www.google.com/search?q="
        case .bing:
            baseURL = "https://www.bing.com/search?q="
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: baseURL + encodedQuery)
    }
}
