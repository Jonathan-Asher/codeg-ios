import Observation
import SwiftUI
import UIKit
import XCTest
@testable import Codeg

/// The Activity feed's newest end and the reader's place: older sessions go
/// in above the rows being read without moving them, a tap on the Activity
/// tab brings the feed to its newest end, coming back to the tab lands there
/// unless the feed was just left scrolled away from it, and the system's
/// scroll to the top is off where the top is the oldest end.
@MainActor
final class ActivityNewestEndTests: XCTestCase {
    // MARK: - Where a size change holds

    func testOlderRowsGoingInKeepTheBottomWhereItIs() {
        XCTAssertTrue(ActivityFeedLayout.keepsBottomOnSizeChange(newestAtBottom: true, pinned: true,
                                                                 holdingForEarlier: false), "pinned to the newest row")
        XCTAssertTrue(ActivityFeedLayout.keepsBottomOnSizeChange(newestAtBottom: true, pinned: false,
                                                                 holdingForEarlier: true),
                      "older rows going in above the rows being read")
        XCTAssertFalse(ActivityFeedLayout.keepsBottomOnSizeChange(newestAtBottom: true, pinned: false,
                                                                  holdingForEarlier: false),
                       "scrolled up: new rows below don't move it")
        XCTAssertFalse(ActivityFeedLayout.keepsBottomOnSizeChange(newestAtBottom: false, pinned: true,
                                                                  holdingForEarlier: true),
                       "newest first: older rows go in below, the top stays")
    }

    func testTheNewestEndIsTheBottomOrTheTop() {
        XCTAssertTrue(ActivityFeedLayout.showsNewest(newestAtBottom: true, pinned: true, atTop: false))
        XCTAssertFalse(ActivityFeedLayout.showsNewest(newestAtBottom: true, pinned: false, atTop: true))
        XCTAssertTrue(ActivityFeedLayout.showsNewest(newestAtBottom: false, pinned: false, atTop: true))
        XCTAssertFalse(ActivityFeedLayout.showsNewest(newestAtBottom: false, pinned: true, atTop: false))
    }

    // MARK: - The tab

    func testComingBackLandsOnTheNewestEndUnlessJustLeftScrolledAway() {
        let now = Date()
        var tab = ActivityTabReturn()
        XCTAssertTrue(tab.landsOnNewest(at: now), "never left")
        tab.left(awayFromNewest: false, at: now)
        XCTAssertTrue(tab.landsOnNewest(at: now.addingTimeInterval(5)))
        tab.left(awayFromNewest: true, at: now)
        XCTAssertFalse(tab.landsOnNewest(at: now.addingTimeInterval(20)), "left scrolled up a moment ago")
        XCTAssertTrue(tab.landsOnNewest(at: now.addingTimeInterval(ActivityTabReturn.keepsPlaceFor)))
    }

    func testATapOnTheActivityTabBringsTheFeedToItsNewestEnd() throws {
        let suite = "activity-tab-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppModel(serverStore: ServerStore(defaults: defaults), defaults: defaults, transcriptCache: nil)
        app.setLayout(compact: true, initial: true)

        app.tapTab(.chats)
        var request = app.activityNewestRequest
        app.tapTab(.activity)
        XCTAssertEqual(app.selectedTab, .activity)
        XCTAssertEqual(app.activityNewestRequest, request + 1, "coming from another tab lands on the newest end")

        request = app.activityNewestRequest
        app.tapTab(.activity)
        XCTAssertEqual(app.activityNewestRequest, request + 1, "a tap on the tab that shows")

        // A session open on the tab: the tab bar takes it back to the feed first.
        app.paths[.activity] = [.conversation(7)]
        request = app.activityNewestRequest
        app.tapTab(.activity)
        XCTAssertEqual(app.activityNewestRequest, request)
        app.paths[.activity] = []

        // Left scrolled up a moment ago: back where it was.
        app.activityFeedAwayFromNewest = true
        app.tapTab(.search)
        request = app.activityNewestRequest
        app.tapTab(.activity)
        XCTAssertEqual(app.activityNewestRequest, request, "where he left it")

        // A tap on another tab that shows does nothing to Activity.
        request = app.activityNewestRequest
        app.tapTab(.activity)
        app.tapTab(.chats)
        app.tapTab(.chats)
        XCTAssertEqual(app.activityNewestRequest, request + 1)
    }

    // MARK: - On the simulator

    private func host<V: View>(_ view: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        return window
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews(in:))
    }

    private func settle(_ seconds: TimeInterval = 0.8) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @Observable
    final class Rows {
        var older = 0
    }

    /// Rows of one height in a scroll view anchored as the feed is while
    /// older sessions go in.
    private struct Feed: View {
        let rows: Rows

        var body: some View {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(-rows.older..<40, id: \.self) { index in
                        Text(verbatim: "Row \(index)")
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                    }
                }
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(
                ActivityFeedLayout.keepsBottomOnSizeChange(newestAtBottom: true, pinned: false, holdingForEarlier: true)
                    ? UnitPoint.bottom : UnitPoint.top,
                for: .sizeChanges
            )
        }
    }

    func testOlderRowsOpenAboveTheRowsBeingRead() throws {
        let rows = Rows()
        let window = try host(Feed(rows: rows))
        defer { window.isHidden = true }
        settle()
        let scroll = try XCTUnwrap(scrollViews(in: window).first)
        // Scrolled up some way, reading.
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentOffset.y - 900)), animated: false)
        settle(0.4)
        let offset = scroll.contentOffset.y
        let belowTheScreen = scroll.contentSize.height - offset

        rows.older = 20
        settle()
        XCTAssertEqual(scroll.contentSize.height - scroll.contentOffset.y, belowTheScreen, accuracy: 1,
                       "the rows on the screen stay where they are")
        XCTAssertEqual(scroll.contentOffset.y - offset, 20 * 68, accuracy: 2, "the older rows went in above")
    }

    private func feed(newestAtBottom: Bool) -> ActivityFeed {
        let sessions = SampleSessions.activitySplit(SampleSessions.all())
        return ActivityFeed(
            running: sessions.running,
            recent: sessions.recent,
            folderNames: SampleSessions.folders,
            lastRefreshed: Date(),
            error: nil,
            onOpen: { _ in },
            onRefresh: {},
            onDismissError: {},
            newestAtBottom: newestAtBottom
        )
    }

    func testTheSystemsScrollToTheTopIsOffWhereTheTopIsTheOldestEnd() throws {
        let bottom = try host(feed(newestAtBottom: true))
        settle()
        XCTAssertEqual(scrollViews(in: bottom).first?.scrollsToTop, false)
        bottom.isHidden = true

        let top = try host(feed(newestAtBottom: false))
        settle()
        XCTAssertEqual(scrollViews(in: top).first?.scrollsToTop, true)
        top.isHidden = true
    }
}
