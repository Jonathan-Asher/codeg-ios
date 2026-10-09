import XCTest
@testable import Codeg

/// The Activity tab's order (newest first, or newest at the bottom) and the
/// bottom pin that keeps a newest-at-the-bottom list on its newest row.
final class ActivityFeedLayoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private var split: (running: [ConversationSummary], recent: [ConversationSummary]) {
        SampleSessions.activitySplit(SampleSessions.all(now: now), now: now)
    }

    // MARK: - Order

    func testNewestFirstKeepsRunningOnTopMostRecentFirst() {
        let sections = ActivityFeedLayout.sections(
            running: split.running, recent: split.recent, newestAtBottom: false)
        XCTAssertEqual(sections.map(\.kind), [.running, .recent])
        XCTAssertEqual(sections[0].rows.map(\.id), [101, 102, 103, 104])
        XCTAssertEqual(sections[1].rows.first?.id, 105)
        for section in sections {
            XCTAssertEqual(section.rows.map(\.updatedAt), section.rows.map(\.updatedAt).sorted(by: >))
        }
    }

    func testNewestAtBottomTurnsTheWholeFeedOver() {
        let sections = ActivityFeedLayout.sections(
            running: split.running, recent: split.recent, newestAtBottom: true)
        // Last 24 Hours first, Running last: the running sessions are the most
        // recent, so they end up nearest the bottom.
        XCTAssertEqual(sections.map(\.kind), [.recent, .running])
        // Oldest first inside each section.
        for section in sections {
            XCTAssertEqual(section.rows.map(\.updatedAt), section.rows.map(\.updatedAt).sorted(by: <))
        }
        let flat = sections.flatMap(\.rows)
        // The most recently updated session is the very last row, the oldest
        // one in the last 24 hours the first.
        XCTAssertEqual(flat.last?.id, 101)
        XCTAssertEqual(flat.first?.id, 112)
        // Same rows, nothing lost or doubled.
        XCTAssertEqual(Set(flat.map(\.id)), Set((split.running + split.recent).map(\.id)))
        XCTAssertEqual(flat.count, split.running.count + split.recent.count)
    }

    func testEachHeaderStaysWithItsOwnRows() {
        for newestAtBottom in [false, true] {
            let sections = ActivityFeedLayout.sections(
                running: split.running, recent: split.recent, newestAtBottom: newestAtBottom)
            for section in sections {
                switch section.kind {
                case .running: XCTAssertTrue(section.rows.allSatisfy { $0.status.isLive })
                case .recent, .earlier: XCTAssertTrue(section.rows.allSatisfy { !$0.status.isLive })
                }
            }
        }
    }

    func testEmptySectionsAreDropped() {
        XCTAssertTrue(ActivityFeedLayout.sections(running: [], recent: [], newestAtBottom: true).isEmpty)
        let onlyRecent = ActivityFeedLayout.sections(running: [], recent: split.recent, newestAtBottom: true)
        XCTAssertEqual(onlyRecent.map(\.kind), [.recent])
        let onlyRunning = ActivityFeedLayout.sections(running: split.running, recent: [], newestAtBottom: false)
        XCTAssertEqual(onlyRunning.map(\.kind), [.running])
    }

    // MARK: - At the bottom

    func testIsAtBottom() {
        // 2000 pt of content in an 800 pt viewport with an 80 pt tab bar inset:
        // the bottom offset is 2000 - 800 + 80 = 1280.
        func at(_ offset: CGFloat) -> Bool {
            BottomPin.isAtBottom(contentHeight: 2000, containerHeight: 800, offsetY: offset, bottomInset: 80)
        }
        XCTAssertTrue(at(1280))
        XCTAssertTrue(at(1280 - BottomPin.tolerance))
        XCTAssertFalse(at(1280 - BottomPin.tolerance - 1))
        XCTAssertFalse(at(0))
        // Rubber-banding past the end still counts.
        XCTAssertTrue(at(1320))
        // Content shorter than the viewport is always at the bottom.
        XCTAssertTrue(BottomPin.isAtBottom(contentHeight: 300, containerHeight: 800, offsetY: -100, bottomInset: 80))
    }

    // MARK: - Pinning

    func testStartsPinned() {
        XCTAssertTrue(BottomPin().isPinned)
    }

    func testUserScrollingUpUnpinsAndBackDownPins() {
        var pin = BottomPin()
        pin.update(atBottom: false, userScrolling: true)
        XCTAssertFalse(pin.isPinned)
        pin.update(atBottom: true, userScrolling: true)
        XCTAssertTrue(pin.isPinned)
    }

    func testNewRowsNeverUnpin() {
        // New or taller rows push the end of the content below the viewport
        // for a moment; that is not the user leaving the bottom.
        var pin = BottomPin()
        pin.update(atBottom: false, userScrolling: false)
        XCTAssertTrue(pin.isPinned)
    }

    func testScrolledUpStaysPutWhenRowsChange() {
        var pin = BottomPin()
        pin.update(atBottom: false, userScrolling: true)
        pin.update(atBottom: false, userScrolling: false)
        XCTAssertFalse(pin.isPinned, "a refresh must not yank a scrolled-up list down")
    }

    func testLayoutLandingAtTheBottomRepins() {
        // E.g. sessions aged out of the last 24 hours and the list got short.
        var pin = BottomPin()
        pin.update(atBottom: false, userScrolling: true)
        pin.update(atBottom: true, userScrolling: false)
        XCTAssertTrue(pin.isPinned)
    }

    func testReset() {
        var pin = BottomPin()
        pin.update(atBottom: false, userScrolling: true)
        pin.reset()
        XCTAssertTrue(pin.isPinned)
    }

    // MARK: - Setting

    @MainActor
    func testNewestAtBottomIsOnByDefaultAndReadsTheStoredChoice() throws {
        let suite = "codeg.tests.appearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(AppearanceStore(defaults: defaults).newestAtBottom)
        defaults.set(false, forKey: "codeg.activity.newestAtBottom")
        XCTAssertFalse(AppearanceStore(defaults: defaults).newestAtBottom)
    }
}
