import SwiftUI
import UIKit
import XCTest
@testable import Codeg

/// Renders the Talk sheet in each of its states (listening, hearing,
/// speaking, asking, background work, muted by voice, an error), in light
/// and dark and at a large text size, through ``Shot``. The states come from
/// ``TalkController/showForScreenshot(_:)`` on a controller over fakes;
/// nothing listens or speaks. The files go with the compose area's
/// (`$COMPOSE_SHOTS_DIR`), named `talk-<state>-<style>.png`.
@MainActor
final class TalkScreenshotTests: XCTestCase {
    private let stats = SessionStats(totalUsage: nil, totalTokens: 182_000, totalDurationMs: 0,
                                     contextWindowUsedTokens: 68_000, contextWindowMaxTokens: 200_000,
                                     contextWindowUsagePercent: 34)

    func testEveryState() throws {
        for state in TalkController.ScreenshotState.allCases {
            try shoot(state)
        }
    }

    func testLargeText() throws {
        try shoot(.speaking, styles: [.light], dynamicType: .accessibility2, suffix: "-ax")
        try shoot(.asking, styles: [.dark], dynamicType: .accessibility2, suffix: "-ax")
    }

    func testTheModelsSheet() throws {
        for style in Shot.styles {
            try Shot.capture("talk-models", style, in: Shot.composeDirectory) {
                TalkModelsSheet(onStart: {}, onCancel: {})
            }
        }
    }

    private func shoot(_ state: TalkController.ScreenshotState, styles: [UIUserInterfaceStyle] = Shot.styles,
                       dynamicType: DynamicTypeSize = .large, suffix: String = "") throws {
        for style in styles {
            let harness = TalkHarness()
            harness.controller.showForScreenshot(state)
            try Shot.capture("talk-\(state.rawValue)\(suffix)", style, dynamicType: dynamicType,
                             in: Shot.composeDirectory) {
                TalkSheet(talk: harness.controller, stats: state == .background ? stats : nil, onEnd: {})
            }
        }
    }
}
