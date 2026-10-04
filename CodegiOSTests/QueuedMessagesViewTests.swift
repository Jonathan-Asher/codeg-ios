import XCTest
@testable import Codeg

/// The queued-message rows: the menu lists the same actions in every state
/// (an open menu whose items change under it closes), and the view only
/// re-renders when the queue or "send now" changes, not on every streamed
/// update.
final class QueuedMessagesViewTests: XCTestCase {
    private func item(_ text: String) -> SessionDetailViewModel.QueuedMessage {
        SessionDetailViewModel.QueuedMessage(id: UUID(), text: text, attachments: [], holdUntilTurnEnd: false)
    }

    private func view(_ items: [SessionDetailViewModel.QueuedMessage], canSendNow: Bool,
                      onRemove: @escaping (UUID) -> Void = { _ in }) -> QueuedMessagesView {
        QueuedMessagesView(items: items, canSendNow: canSendNow, onSendNow: { _ in }, onEdit: { _ in },
                           onRemove: onRemove)
    }

    func testTheMenuHasTheSameItemsWhetherOrNotItCanSendNow() {
        XCTAssertEqual(QueuedMessagesView.Action.allCases, [.sendNow, .edit, .remove])
        XCTAssertTrue(QueuedMessagesView.Action.sendNow.isEnabled(canSendNow: true))
        XCTAssertFalse(QueuedMessagesView.Action.sendNow.isEnabled(canSendNow: false))
        for canSendNow in [true, false] {
            XCTAssertTrue(QueuedMessagesView.Action.edit.isEnabled(canSendNow: canSendNow))
            XCTAssertTrue(QueuedMessagesView.Action.remove.isEnabled(canSendNow: canSendNow))
        }
        XCTAssertEqual(QueuedMessagesView.Action.remove.title, "Remove")
    }

    func testItOnlyChangesWithTheQueueOrSendNow() {
        let a = item("first")
        let b = item("second")
        var removed: [UUID] = []
        let one = view([a, b], canSendNow: false)
        // New closures (every parent render makes new ones) are the same view.
        let again = view([a, b], canSendNow: false) { removed.append($0) }
        XCTAssertEqual(one, again)
        XCTAssertNotEqual(one, view([a, b], canSendNow: true))
        XCTAssertNotEqual(one, view([a], canSendNow: false))
        XCTAssertNotEqual(one, view([b, a], canSendNow: false))

        again.onRemove(b.id)
        XCTAssertEqual(removed, [b.id])
    }
}
