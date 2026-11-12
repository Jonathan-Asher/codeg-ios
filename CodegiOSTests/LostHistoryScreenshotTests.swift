import SwiftUI
import UIKit
import XCTest
@testable import Codeg

/// How the resume dividers and a session whose history is gone look, through
/// the same window capture as ``SessionListScreenshotTests``: in
/// `$COMPOSE_SHOTS_DIR`, `resume-dividers-*.png` (in the transcript),
/// `resume-dividers-open-*.png` (a tap opened their lists),
/// `history-unavailable-saved-*.png` (the server's saved text) and
/// `history-unavailable-kept-*.png` (the copy kept on this iPhone), in light
/// and dark, and in Simplified Chinese.
@MainActor
final class LostHistoryScreenshotTests: XCTestCase {
    private let backgroundResume = [
        ContinuePrompt.resumeBackgroundHead,
        "- sub-agent: Review the parser (started 13:02)",
        "- background shell: npm run e2e",
        ContinuePrompt.resumeBackgroundTail,
    ].joined(separator: "\n")

    private var turnResume: String {
        ContinuePrompt.resumeAfterRestart + "\n\n" + ContinuePrompt.resumeTurnBackgroundHeader
            + "\n- monitor: e2e run: errors"
    }

    private func turn(_ id: String, _ role: TurnRole, _ text: String, minutesAgo: Double) -> MessageTurn {
        MessageTurn(id: id, role: role, blocks: [.text(text)], timestamp: Date().addingTimeInterval(-minutesAgo * 60))
    }

    private let lost = HistoryUnavailable(reason: .agentCleanup, retentionDays: 30, savedTurns: 4)

    func testResumeDividers() throws {
        let turns = [
            turn("u-1", .user, "Run the end-to-end suite and fix what fails", minutesAgo: 30),
            turn("a-1", .assistant, "Started the suite in the background, and a sub-agent reviewing the parser.",
                 minutesAgo: 29),
            turn("u-2", .user, backgroundResume, minutesAgo: 12),
            turn("a-2", .assistant, "Re-launched the e2e run and the parser review.", minutesAgo: 11),
            turn("u-3", .user, turnResume, minutesAgo: 4),
            turn("a-3", .assistant, "Picked the fix back up; the monitor is watching the run again.", minutesAgo: 3),
        ]
        func transcript(_ locale: Locale) -> some View {
            ZStack {
                CodegBackground()
                TranscriptView(turns: turns, pendingUserTurns: [], liveTurn: nil, agent: .claudeCode, turnsVersion: 1,
                               scrollTick: 0, stickTick: 0, onPinnedChange: { _ in }) { EmptyView() }
            }
            .environment(\.locale, locale)
        }
        let background = try XCTUnwrap(ContinuePrompt.divider(ofText: backgroundResume))
        let cutOff = try XCTUnwrap(ContinuePrompt.divider(ofText: turnResume))
        func opened(_ locale: Locale) -> some View {
            ZStack(alignment: .top) {
                CodegBackground()
                VStack(spacing: 28) {
                    ContinuationDivider(divider: background, expanded: true)
                    ContinuationDivider(divider: cutOff, expanded: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 120)
            }
            .environment(\.locale, locale)
        }
        for style in Shot.styles {
            try Shot.capture("resume-dividers", style, in: Shot.composeDirectory, settle: 1.5) {
                transcript(Locale(identifier: "en"))
            }
            try Shot.capture("resume-dividers-open", style, in: Shot.composeDirectory) {
                opened(Locale(identifier: "en"))
            }
        }
        try Shot.capture("resume-dividers-zh", .light, in: Shot.composeDirectory, settle: 1.5) {
            transcript(Locale(identifier: "zh-Hans"))
        }
        try Shot.capture("resume-dividers-open-zh", .light, in: Shot.composeDirectory) {
            opened(Locale(identifier: "zh-Hans"))
        }
    }

    func testASessionWhoseHistoryIsGone() throws {
        let saved = [
            SavedTurn(turnIdx: 0, role: .user, content: "Find alternatives to Higgsfield for video generation"),
            SavedTurn(turnIdx: 1, role: .assistant, content: """
                I started four research tracks:

                1. **Seedance 2.5** for motion quality
                2. **Kling** for longer clips
                """),
            SavedTurn(turnIdx: 4, role: .user, content: "What about pricing?"),
            SavedTurn(turnIdx: 5, role: .assistant, content: "Seedance is the cheapest per second of the four."),
        ]
        func savedCopy(_ locale: Locale) -> some View {
            ZStack {
                CodegBackground()
                SavedHistoryView(state: .loaded(saved), savedTurns: saved.count, agentName: "Claude Code",
                                 onRetry: {})
                    .safeAreaInset(edge: .bottom) {
                        HistoryUnavailableBanner(info: lost, agentName: "Claude Code", copy: .saved, onStartNew: {})
                    }
            }
            .environment(\.locale, locale)
        }
        let kept = [
            turn("turn-0", .user, "Find alternatives to Higgsfield for video generation", minutesAgo: 60 * 24 * 49),
            turn("turn-1", .assistant, "I started four research tracks: Seedance 2.5, Kling, Veo and Runway.",
                 minutesAgo: 60 * 24 * 49 - 2),
            turn("turn-2", .user, "Compare their prices", minutesAgo: 60 * 24 * 48),
        ]
        func keptCopy(_ locale: Locale) -> some View {
            ZStack {
                CodegBackground()
                TranscriptView(turns: kept, pendingUserTurns: [], liveTurn: nil, agent: .claudeCode, turnsVersion: 1,
                               scrollTick: 0, stickTick: 0, onPinnedChange: { _ in }) {
                    KeptCopyLabel()
                }
                .safeAreaInset(edge: .bottom) {
                    HistoryUnavailableBanner(info: lost, agentName: "Claude Code", copy: .iPhone, unsentCount: 1,
                                             onStartNew: {})
                }
            }
            .environment(\.locale, locale)
        }
        for style in Shot.styles {
            try Shot.capture("history-unavailable-saved", style, in: Shot.composeDirectory, settle: 1.5) {
                savedCopy(Locale(identifier: "en"))
            }
            try Shot.capture("history-unavailable-kept", style, in: Shot.composeDirectory, settle: 1.5) {
                keptCopy(Locale(identifier: "en"))
            }
        }
        try Shot.capture("history-unavailable-saved-zh", .light, in: Shot.composeDirectory, settle: 1.5) {
            savedCopy(Locale(identifier: "zh-Hans"))
        }
        try Shot.capture("history-unavailable-kept-zh", .light, in: Shot.composeDirectory, settle: 1.5) {
            keptCopy(Locale(identifier: "zh-Hans"))
        }
    }
}
