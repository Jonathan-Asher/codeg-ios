import Foundation
import UserNotifications

// Compiled into both the app and the notification service extension
// (NotificationService/), so it uses Foundation and UserNotifications only.

/// Lenient readers for the custom fields of a push's `userInfo`: APNs hands
/// JSON numbers over as `NSNumber`, and a field may arrive as a string.
enum PushValue {
    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["true", "1"].contains(s.lowercased())
        default: return nil
        }
    }
}

/// The `question` object of a question push (codeg `docs/ios-push.md` §5):
/// the first question of the set the agent asked.
struct PushQuestion: Equatable, Sendable {
    /// The question set's id: `acp_answer_question`'s `questionId`.
    var questionID: String
    /// This question's id inside the set: the answer item's `questionId`.
    var itemID: String
    var text: String
    var header: String
    var multiSelect: Bool
    /// The full option labels.
    var options: [String]
    /// How many questions the set holds.
    var count: Int
    /// One single-choice question whose labels all fit a button.
    var answerable: Bool

    init(questionID: String, itemID: String, text: String = "", header: String = "", multiSelect: Bool = false,
         options: [String] = [], count: Int = 1, answerable: Bool = false) {
        self.questionID = questionID
        self.itemID = itemID
        self.text = text
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
        self.count = count
        self.answerable = answerable
    }

    /// Nil when the object is missing or has no ids.
    init?(_ raw: Any?) {
        guard let dict = raw as? [AnyHashable: Any],
              let questionID = PushValue.string(dict["question_id"]),
              let itemID = PushValue.string(dict["item_id"]) else { return nil }
        self.questionID = questionID
        self.itemID = itemID
        text = PushValue.string(dict["text"]) ?? ""
        header = PushValue.string(dict["header"]) ?? ""
        multiSelect = PushValue.bool(dict["multi_select"]) ?? false
        options = (dict["options"] as? [Any])?.compactMap { PushValue.string($0) } ?? []
        count = PushValue.int(dict["count"]) ?? 1
        answerable = PushValue.bool(dict["answerable"]) ?? false
    }
}

/// Answer buttons on a question push. Action titles are fixed when a category
/// is registered, so the notification service extension registers one
/// category per set of option labels (`CODEG_QUESTION.<hash>`) and points the
/// notification at it. Without the extension, or for a question that can't be
/// answered with one tap, the push keeps `CODEG_QUESTION` (Open only).
enum QuestionCategory {
    /// The category the server names.
    static let base = "CODEG_QUESTION"
    /// Prefix of the per-labels categories.
    static let prefix = "CODEG_QUESTION."
    /// `ANSWER_<i>` answers with option `i`.
    static let answerPrefix = "ANSWER_"
    static let openAction = "OPEN"
    /// iOS shows about four actions on a notification. A question with more
    /// options gets Open only.
    static let maxButtons = 4
    /// How many per-labels categories stay registered.
    static let keep = 24

    /// The labels to offer as buttons, or nil when the question gets Open
    /// only: several questions, multiple choice, free text, or too many
    /// options.
    static func buttonLabels(for question: PushQuestion) -> [String]? {
        guard question.answerable, !question.multiSelect, question.count <= 1,
              !question.options.isEmpty, question.options.count <= maxButtons,
              !question.options.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        return question.options
    }

    /// `CODEG_QUESTION.<16 hex digits>`: the same labels always give the same
    /// category, in the app and in the extension (FNV-1a, not the seeded
    /// `Hasher`).
    static func identifier(for labels: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for (index, label) in labels.enumerated() {
            if index > 0 { hash = (hash ^ 0x1f) &* 0x0000_0100_0000_01b3 }
            for byte in label.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        }
        return prefix + String(format: "%016llx", hash)
    }

    /// One action per label (`ANSWER_0`…, run in the background on an
    /// unlocked device), then Open while there is room.
    static func make(labels: [String], openTitle: String) -> UNNotificationCategory {
        var actions = labels.enumerated().map { index, label in
            UNNotificationAction(identifier: answerPrefix + String(index), title: label,
                                 options: [.authenticationRequired])
        }
        if labels.count < maxButtons {
            actions.append(UNNotificationAction(
                identifier: openAction, title: openTitle, options: [.foreground],
                icon: UNNotificationActionIcon(systemImageName: "arrow.up.forward.app")))
        }
        return UNNotificationCategory(identifier: identifier(for: labels), actions: actions,
                                      intentIdentifiers: [], options: [])
    }

    /// The option index an `ANSWER_<i>` action stands for.
    static func answerIndex(_ actionIdentifier: String) -> Int? {
        guard actionIdentifier.hasPrefix(answerPrefix) else { return nil }
        guard let index = Int(actionIdentifier.dropFirst(answerPrefix.count)), index >= 0 else { return nil }
        return index
    }

    static func isPerQuestion(_ identifier: String) -> Bool { identifier.hasPrefix(prefix) }

    /// The registered categories with `category` added. At most `keep`
    /// per-labels categories stay; the others go first (the set has no order,
    /// so which ones is arbitrary, but never the new one).
    static func merged(_ existing: Set<UNNotificationCategory>,
                       adding category: UNNotificationCategory) -> Set<UNNotificationCategory> {
        var fixed = existing.filter { !isPerQuestion($0.identifier) }
        var perQuestion = existing.filter { isPerQuestion($0.identifier) && $0.identifier != category.identifier }
            .sorted { $0.identifier < $1.identifier }
        if perQuestion.count > keep - 1 { perQuestion = Array(perQuestion.prefix(keep - 1)) }
        fixed.formUnion(perQuestion)
        fixed.insert(category)
        return fixed
    }

    /// The app's fixed categories plus the per-labels ones the extension
    /// registered, which `setNotificationCategories` would otherwise drop.
    static func preserving(_ existing: Set<UNNotificationCategory>,
                           fixed: Set<UNNotificationCategory>) -> Set<UNNotificationCategory> {
        let fixedIDs = Set(fixed.map(\.identifier))
        let perQuestion = existing.filter { isPerQuestion($0.identifier) && !fixedIDs.contains($0.identifier) }
            .sorted { $0.identifier < $1.identifier }
            .prefix(keep)
        return fixed.union(perQuestion)
    }
}

/// Wording the extension adds to a question push.
enum QuestionPushWording {
    /// The subtitle of the n-th reminder: "Still waiting · reminder 2".
    static func reminderSubtitle(attempt: Int) -> String {
        String(localized: "Still waiting · reminder \(attempt)", bundle: .codegApp)
    }

    static var openTitle: String { String(localized: "Open", bundle: .codegApp) }
}

extension Bundle {
    /// The app's bundle, also from inside the notification service extension
    /// (Codeg.app/PlugIns/NotificationService.appex), so both read the app's
    /// string catalog.
    static let codegApp: Bundle = {
        let main = Bundle.main
        guard main.bundleURL.pathExtension == "appex" else { return main }
        let app = main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: app) ?? main
    }()
}
