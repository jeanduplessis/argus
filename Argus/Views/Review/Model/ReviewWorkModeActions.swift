import Foundation

enum WorkModeStorage {
    static let key = "Argus.workMode"
    static let defaultValue = WorkMode.code.rawValue

    static func parse(_ value: String?) -> WorkMode {
        WorkMode(rawValue: value ?? defaultValue) ?? .code
    }

    static func read(from defaults: UserDefaults = .standard) -> WorkMode {
        parse(defaults.string(forKey: key))
    }
}

enum WorkModeTabCommand {
    case close
    case selectPrevious
    case selectNext
}

enum WorkModeTabCommandRoute: Equatable {
    case closeReviewTab
    case selectReviewTab(offset: Int)
    case closeCodeTab
    case selectCodeTab(offset: Int)
}

enum WorkModeTabCommandRouter {
    static func route(_ command: WorkModeTabCommand, in workMode: WorkMode) -> WorkModeTabCommandRoute {
        switch (workMode, command) {
        case (.review, .close): .closeReviewTab
        case (.review, .selectPrevious): .selectReviewTab(offset: -1)
        case (.review, .selectNext): .selectReviewTab(offset: 1)
        case (.code, .close): .closeCodeTab
        case (.code, .selectPrevious): .selectCodeTab(offset: -1)
        case (.code, .selectNext): .selectCodeTab(offset: 1)
        }
    }
}

enum WorkModeCodeCommandEligibility {
    static func isEnabled(in workMode: WorkMode) -> Bool {
        workMode == .code
    }
}

struct SubmitReviewConfirmation: Identifiable {
    let id = UUID()
    let pullRequestNumber: Int
    let pendingReview: PendingReview

    var disposition: ReviewDisposition { pendingReview.disposition! }

    var inlineDraftDescription: String {
        let count = pendingReview.inlineDrafts.count
        return "\(count) inline \(count == 1 ? "draft" : "drafts")"
    }

    var summaryDescription: String {
        pendingReview.summary.isEmpty ? "No summary will be included." : "A summary will be included."
    }

    var message: String {
        "Submit \(disposition.rawValue) for Pull Request #\(pullRequestNumber) with \(inlineDraftDescription). \(summaryDescription)"
    }
}

enum ReviewSubmissionEligibility {
    static func canSubmit(
        pendingReview: PendingReview,
        providerWriteEligible: Bool,
        isSubmitting: Bool
    ) -> Bool {
        pendingReview.revision != nil
            && pendingReview.disposition != nil
            && providerWriteEligible
            && !isSubmitting
    }
}
