import SwiftUI
import UIKit
import XCTest
@testable import Codeg

/// Renders the session lists (the row styles, the Chats folder cards, a
/// folder's full list and the Activity tab) with ``SampleSessions`` to PNG, in
/// light and dark, at the simulator's screen size. CI runs the tests on an
/// iPhone 17 Pro Max simulator and uploads the files as an artifact.
///
/// `ImageRenderer` can't draw `List`, `ScrollView`, navigation bars or tab bars
/// (they are UIKit-backed), so each screen is hosted in its own window and
/// captured with `drawHierarchy`, which draws what the screen shows.
///
/// The files go to `$LIST_SHOTS_DIR` (CI sets `TEST_RUNNER_LIST_SHOTS_DIR`),
/// or to `build/list-shots/` in the checkout.
@MainActor
final class SessionListScreenshotTests: XCTestCase {
    private let now = Date()
    /// The session marked as the one you came from.
    private static let marked = 105
    private var sessions: [ConversationSummary] { SampleSessions.all(now: now) }

    override func setUp() async throws {
        AttentionStore.shared.update(SampleSessions.needsYou)
    }

    override func tearDown() async throws {
        AttentionStore.shared.clear()
    }

    func testRenderRows() throws {
        for style in Shot.styles {
            try Shot.capture("rows", style) {
                ZStack(alignment: .top) {
                    CodegBackground()
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(sessions.prefix(8)) { conv in
                                SessionRow(
                                    conversation: conv,
                                    isSelected: conv.id == Self.marked,
                                    folderName: SampleSessions.folders[conv.folderId],
                                    onTap: {}
                                )
                            }
                        }
                        .padding(.horizontal, Theme.Layout.screenHMargin)
                        .padding(.vertical, 24)
                    }
                }
            }
        }
        // Dynamic Type at an accessibility size.
        try Shot.capture("rows-xxl", .light, dynamicType: .accessibility2) {
            ZStack(alignment: .top) {
                CodegBackground()
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(sessions.prefix(4)) { conv in
                            SessionRow(
                                conversation: conv,
                                isSelected: false,
                                folderName: SampleSessions.folders[conv.folderId],
                                onTap: {}
                            )
                        }
                    }
                    .padding(.horizontal, Theme.Layout.screenHMargin)
                    .padding(.vertical, 24)
                }
            }
        }
    }

    func testRenderChats() throws {
        let all = sessions
        let pinned = all.filter(\.isPinned).sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
        let groups = SampleSessions.folders.keys.sorted().map { fid in
            (fid, all.filter { $0.folderId == fid && !$0.isPinned }.sorted { $0.updatedAt > $1.updatedAt })
        }
        for style in Shot.styles {
            try Shot.capture("chats", style) {
                Shot.tabs(selected: 0) {
                    ZStack {
                        CodegBackground()
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                SessionSectionCard(
                                    title: "Pinned", tint: Theme.accent, conversations: pinned,
                                    folderName: { SampleSessions.folders[$0.folderId] },
                                    markedID: Self.marked, onOpen: { _ in }, onTogglePin: { _ in },
                                    onExpand: {}
                                )
                                .padding(.horizontal, Theme.Layout.screenHMargin)
                                ForEach(groups, id: \.0) { fid, convs in
                                    SessionSectionCard(
                                        title: SampleSessions.folders[fid] ?? "",
                                        tint: Color(hexString: SampleSessions.folderColors[fid] ?? "") ?? Theme.accent,
                                        conversations: convs,
                                        markedID: Self.marked, onOpen: { _ in }, onTogglePin: { _ in },
                                        onExpand: {}
                                    )
                                    .padding(.horizontal, Theme.Layout.screenHMargin)
                                }
                            }
                            .padding(.top, Theme.Layout.screenTopInset)
                            .padding(.bottom, Theme.Layout.screenBottomInset)
                        }
                    }
                    .navigationTitle("")
                    .toolbarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            HStack(spacing: 5) {
                                Text(verbatim: "codeg box")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(Theme.textPrimary)
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .fixedSize()
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                }
            }
        }
    }

    func testRenderFolderList() throws {
        let convs = sessions.filter { $0.folderId == 1 || $0.folderId == 2 }
            .sorted { $0.updatedAt > $1.updatedAt }
        for style in Shot.styles {
            try Shot.capture("folder", style) {
                SessionSectionFullScreen(
                    title: "codeg-ios",
                    tint: Color(hexString: SampleSessions.folderColors[2] ?? "") ?? Theme.accent,
                    conversations: convs,
                    folderName: { SampleSessions.folders[$0.folderId] },
                    markedID: Self.marked,
                    onOpen: { _ in },
                    onTogglePin: { _ in },
                    onClose: {}
                )
            }
        }
    }

    func testRenderActivity() throws {
        let split = SampleSessions.activitySplit(sessions, now: now)
        for style in Shot.styles {
            try Shot.capture("activity", style) {
                Shot.tabs(selected: 2) {
                    ZStack {
                        CodegBackground()
                        ActivityFeed(
                            running: split.running,
                            recent: split.recent,
                            folderNames: SampleSessions.folders,
                            markedID: Self.marked,
                            lastRefreshed: now.addingTimeInterval(-20),
                            error: nil,
                            onOpen: { _ in },
                            onRefresh: {},
                            onDismissError: {}
                        )
                    }
                    .screenTitle("Activity", compact: true)
                }
            }
        }
    }
}

// MARK: - Capture

@MainActor
enum Shot {
    static let styles: [UIUserInterfaceStyle] = [.light, .dark]

    /// The app's compact tab shell (Chats · Folders · Activity · Search ·
    /// Settings) around one tab's navigation stack.
    @ViewBuilder
    static func tabs<Content: View>(selected: Int, @ViewBuilder content: () -> Content) -> some View {
        let screen = NavigationStack { content() }
        TabView(selection: .constant(selected)) {
            Tab(value: 0) { if selected == 0 { screen } } label: { tabLabel("Chats", "message") }
            Tab(value: 1) { Color.clear } label: { tabLabel("Folders", "folder") }
            Tab(value: 2) { if selected == 2 { screen } } label: { tabLabel("Activity", "waveform") }
            Tab(value: 3) { Color.clear } label: { tabLabel("Search", "magnifyingglass") }
            Tab(value: 4) { Color.clear } label: { tabLabel("Settings", "gearshape") }
        }
        .tint(Theme.accent)
    }

    /// Outline tab icons, as `RootView.linearTabLabel` draws them.
    private static func tabLabel(_ title: LocalizedStringKey, _ systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .environment(\.symbolVariants, .none)
        }
    }

    static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["LIST_SHOTS_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/list-shots", isDirectory: true)
    }

    /// Hosts `content` full screen in its own window, lets layout, scroll
    /// anchors and images settle, then writes `<name>-<light|dark>.png`.
    static func capture<Content: View>(
        _ name: String,
        _ style: UIUserInterfaceStyle,
        dynamicType: DynamicTypeSize = .large,
        @ViewBuilder _ content: () -> Content
    ) throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.overrideUserInterfaceStyle = style
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: content().dynamicTypeSize(dynamicType))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        settle(1.2)

        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        format.scale = scene.screen.scale
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        let dir = directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suffix = style == .dark ? "dark" : "light"
        let url = dir.appendingPathComponent("\(name)-\(suffix).png")
        try data.write(to: url)
        let size = scene.screen.bounds.size
        print("list-shot: \(url.path) (\(Int(size.width))x\(Int(size.height)) pt @\(Int(scene.screen.scale))x)")
    }

    private static func settle(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
