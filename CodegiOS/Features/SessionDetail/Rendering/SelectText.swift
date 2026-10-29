import SwiftUI
import UIKit

// "Select Text": SwiftUI's `Text` on iPhone selects only the whole of a text
// (a long press offers Copy of all of it, and a message is several texts, one
// per paragraph or run of lines that read the same way). So every message,
// code block and tool output offers Select Text in its long-press menu, which
// opens its content in a sheet with a native selectable text view: drag
// handles, Select All, Copy, Share, Look Up and Translate from the system
// menu, across paragraphs in either direction.

/// Opens the Select Text sheet. Set by a screen that presents it
/// (`selectTextSheet()`); nil elsewhere, where texts keep their own Copy.
struct SelectTextAction: Equatable {
    let presentation: SelectTextPresentation

    /// Shows `source`; a link tapped in it opens with `openURL`, the action
    /// where the text is (which opens a session's media in the app).
    @MainActor
    func callAsFunction(_ source: SelectTextSource, openURL: OpenURLAction? = nil) {
        presentation.open(source, openURL: openURL)
    }

    static func == (a: SelectTextAction, b: SelectTextAction) -> Bool {
        a.presentation === b.presentation
    }
}

private struct SelectTextKey: EnvironmentKey {
    static let defaultValue: SelectTextAction? = nil
}

extension EnvironmentValues {
    var selectText: SelectTextAction? {
        get { self[SelectTextKey.self] }
        set { self[SelectTextKey.self] = newValue }
    }
}

/// What the sheet shows, and the link to open once it has closed.
@MainActor
@Observable
final class SelectTextPresentation {
    struct Item: Identifiable {
        let id = UUID()
        let source: SelectTextSource
        let openURL: OpenURLAction?
    }

    var shown: Item?
    @ObservationIgnored private var pendingLink: (url: URL, openURL: OpenURLAction?)?

    func open(_ source: SelectTextSource, openURL: OpenURLAction?) {
        shown = Item(source: source, openURL: openURL)
    }

    /// A link tapped in the sheet: the sheet closes, then the link opens
    /// (`dismissed`), so what it opens isn't hidden behind the sheet.
    func linkTapped(_ url: URL) {
        pendingLink = (url, shown?.openURL)
        shown = nil
    }

    func dismissed() {
        guard let link = pendingLink else { return }
        pendingLink = nil
        if let openURL = link.openURL {
            openURL(link.url)
        } else {
            UIApplication.shared.open(link.url)
        }
    }
}

extension View {
    /// Offers Select Text to the messages, code blocks and tool outputs in
    /// this view, and presents its sheet.
    func selectTextSheet() -> some View {
        modifier(SelectTextPresenter())
    }

    /// Long press: Copy and Select Text for `source` when `enabled`; nothing
    /// otherwise.
    func selectTextMenu(_ source: @autoclosure () -> SelectTextSource, enabled: Bool) -> some View {
        modifier(SelectTextMenu(source: enabled ? source() : nil))
    }
}

private struct SelectTextPresenter: ViewModifier {
    @State private var presentation = SelectTextPresentation()

    func body(content: Content) -> some View {
        content
            .environment(\.selectText, SelectTextAction(presentation: presentation))
            .sheet(item: $presentation.shown, onDismiss: { presentation.dismissed() }) { item in
                SelectTextSheet(source: item.source) { presentation.linkTapped($0) }
            }
    }
}

private struct SelectTextMenu: ViewModifier {
    let source: SelectTextSource?

    func body(content: Content) -> some View {
        if let source {
            content
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .contextMenu {
                    CopyMenuButton(text: source.raw)
                    SelectTextButton(source: source)
                }
        } else {
            content
        }
    }
}

/// "Copy" in a long-press menu.
struct CopyMenuButton: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}

/// "Select Text" in a long-press menu; nothing where the screen offers no
/// sheet.
struct SelectTextButton: View {
    let source: SelectTextSource
    @Environment(\.selectText) private var selectText
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let selectText, !source.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button {
                selectText(source, openURL: openURL)
            } label: {
                Label("Select Text", systemImage: "selection.pin.in.out")
            }
        }
    }
}

// MARK: - The sheet

/// The text rendered as in the transcript, in a native text view that selects
/// any part of it.
struct SelectTextSheet: View {
    let source: SelectTextSource
    var openLink: ((URL) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            SelectTextView(
                text: SelectTextRenderer.attributed(source, contentSize: UIContentSizeCategory(dynamicTypeSize)),
                openLink: openLink
            )
            .ignoresSafeArea(.container, edges: .bottom)
            .background(CodegBackground())
            .navigationTitle("Select Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationSizing(.page)
    }
}

/// A read-only `UITextView`: selection with handles and the system's edit
/// menu, links that open on a tap.
struct SelectTextView: UIViewRepresentable {
    let text: NSAttributedString
    var openLink: ((URL) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.dataDetectorTypes = []
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        // 16 pt from the edges with the line fragment's own 5 pt, as the
        // transcript's margins; room under the last line past the home bar.
        view.textContainerInset = UIEdgeInsets(top: 14, left: 11, bottom: 40, right: 11)
        view.tintColor = UIColor(Theme.accent)
        view.linkTextAttributes = [.foregroundColor: UIColor(Theme.accent)]
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "select-text"
        view.attributedText = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.openLink = openLink
        if !view.attributedText.isEqual(to: text) {
            view.attributedText = text
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openLink: ((URL) -> Void)?

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content, let openLink else { return defaultAction }
            return UIAction { _ in openLink(url) }
        }
    }
}
