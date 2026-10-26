import Foundation
import UserNotifications

/// Adds answer buttons to codeg's question pushes (`CODEG_QUESTION`, sent with
/// `mutable-content: 1`, codeg `docs/ios-push.md` §6) and says which reminder a
/// reminder is.
///
/// For one single-choice question whose options fit a few buttons, it
/// registers a category whose actions are the option labels
/// (`CODEG_QUESTION.<hash>`, see ``QuestionCategory``) and points the
/// notification at it. Tapping a label answers through `acp_answer_question`
/// in the app's notification response handler, without opening the app. Any
/// other question keeps `CODEG_QUESTION`, whose only button is Open.
final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    /// What to deliver if time runs out before the category is registered.
    private var fallback: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        let info = content.userInfo
        if PushValue.bool(info["reminder"]) == true, let attempt = PushValue.int(info["attempt"]), attempt > 0 {
            content.subtitle = QuestionPushWording.reminderSubtitle(attempt: attempt)
        }
        lock.lock()
        self.contentHandler = contentHandler
        fallback = content.copy() as? UNNotificationContent
        lock.unlock()

        guard content.categoryIdentifier == QuestionCategory.base,
              let question = PushQuestion(info["question"]),
              let labels = QuestionCategory.buttonLabels(for: question) else {
            deliver(content)
            return
        }
        let category = QuestionCategory.make(labels: labels, openTitle: QuestionPushWording.openTitle)
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            center.setNotificationCategories(QuestionCategory.merged(existing, adding: category))
            // Read the set back before delivering: the registration is
            // asynchronous, and a notification whose category is not
            // registered yet shows without its buttons.
            center.getNotificationCategories { _ in
                content.categoryIdentifier = category.identifier
                self.deliver(content)
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let content = fallback
        lock.unlock()
        if let content { deliver(content) }
    }

    /// Hand the content over once.
    private func deliver(_ content: UNNotificationContent) {
        lock.lock()
        let handler = contentHandler
        contentHandler = nil
        lock.unlock()
        handler?(content)
    }
}
