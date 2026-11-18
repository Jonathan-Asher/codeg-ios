import SwiftUI
import UIKit

/// Where a session's side questions show (`/btw`, ``SideQuestionModel``): a
/// panel above the message bar in a regular width (iPad), a sheet in a
/// compact one (iPhone, and an iPad window made narrow). Placed in the
/// compose area like the other cards above the bar; it carries its own sheet
/// and animation, so the session screen's modifiers stay as they are.
struct SideQuestionHost: View {
    let model: SideQuestionModel
    /// The message bar's side margin, which the inline panel matches.
    var sideMargin: CGFloat = 16

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var inline: Bool { horizontalSizeClass == .regular }

    var body: some View {
        VStack(spacing: 0) {
            if inline, model.isOpen {
                SideQuestionPanel(model: model, presentation: .inline)
                    .padding(.horizontal, sideMargin)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.chrome, value: inline && model.isOpen)
        .sheet(isPresented: Binding(
            get: { !inline && model.isOpen },
            set: { shown in if !shown { model.close() } }
        )) {
            SideQuestionPanel(model: model, presentation: .sheet)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// The side question on screen: the question, then a spinner with Cancel
/// until the answer arrives as Markdown, with Copy. Earlier exchanges are a
/// step away. Nothing here is part of the conversation.
struct SideQuestionPanel: View {
    enum Presentation {
        case inline
        case sheet
    }

    let model: SideQuestionModel
    let presentation: Presentation

    /// The entry whose answer was just copied (its button shows a check).
    @State private var copiedID: String?
    /// Measured height of the inline body, so a short answer gets a short
    /// panel and a long one scrolls.
    @State private var bodyHeight: CGFloat = 0

    private static let maxInlineHeight: CGFloat = 300

    var body: some View {
        switch presentation {
        case .inline:
            VStack(alignment: .leading, spacing: 10) {
                header
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
                }
                .frame(height: min(max(bodyHeight, 1), Self.maxInlineHeight))
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(14)
            .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .hairlineBorder(Theme.Radius.lg)
            .shadow(color: .black.opacity(0.14), radius: 12, y: 3)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Side question"))
        case .sheet:
            VStack(alignment: .leading, spacing: 12) {
                header
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Side question")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Not added to the conversation")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if model.entries.count > 1 { pager }
            if let entry = model.current, let answer = entry.record?.answer, !answer.isEmpty {
                copyButton(entry: entry, answer: answer)
            }
            Button { model.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
    }

    private var pager: some View {
        HStack(spacing: 2) {
            Button { model.step(-1) } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.index > 0 ? Theme.textPrimary : Theme.textTertiary)
            .disabled(model.index <= 0)
            .accessibilityLabel(Text("Earlier side question"))

            Text(verbatim: "\(model.index + 1) / \(model.entries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)

            Button { model.step(1) } label: {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.index < model.entries.count - 1 ? Theme.textPrimary : Theme.textTertiary)
            .disabled(model.index >= model.entries.count - 1)
            .accessibilityLabel(Text("Later side question"))
        }
    }

    private func copyButton(entry: SideQuestionModel.Entry, answer: String) -> some View {
        Button {
            UIPasteboard.general.string = answer
            copiedID = entry.id
            AccessibilityNotification.Announcement(String(localized: "Answer copied")).post()
        } label: {
            Image(systemName: copiedID == entry.id ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(copiedID == entry.id ? Theme.accent : Theme.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Copy answer"))
        .task(id: copiedID) {
            guard copiedID != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copiedID = nil }
        }
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if let entry = model.current {
            VStack(alignment: .leading, spacing: 10) {
                MarkdownText(raw: entry.question, color: Theme.textSecondary, font: .subheadline, plain: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                switch entry.status {
                case .pending:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking…")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 8)
                        Button { model.cancel(entry.id) } label: {
                            Text("Cancel")
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .foregroundStyle(Theme.textPrimary)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .accessibilityElement(children: .contain)
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { model.retry(entry.id) } label: {
                            Label("Try Again", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                case .answered(let record):
                    answer(record)
                }
            }
        } else {
            Text("No side questions yet. Type /btw and a question.")
                .font(.subheadline)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func answer(_ record: SideQuestionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if record.synthetic {
                Text("Notice from the agent")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.warning)
            }
            if let answer = record.answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownContent(raw: answer)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("The agent gave no answer.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textTertiary)
            }
            if let note = record.fallbackNotice, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
