import SwiftUI
import UIKit

// MARK: - The action

/// What "Edit Message" does on the open session's messages. Set by the
/// session screen; absent (no Edit offered) anywhere else.
struct MessageEditAction {
    /// Whether the message `turnID` can be edited now.
    let availability: (String) -> MessageEditAvailability
    /// Open the editor on it.
    let start: (String) -> Void
    /// Say why a greyed-out Edit can't run now.
    let explain: (String) -> Void
}

private struct MessageEditKey: EnvironmentKey {
    static let defaultValue: MessageEditAction? = nil
}

extension EnvironmentValues {
    var messageEdit: MessageEditAction? {
        get { self[MessageEditKey.self] }
        set { self[MessageEditKey.self] = newValue }
    }
}

/// A message open in the editor.
struct MessageEditSession: Identifiable, Equatable {
    /// The message's turn id.
    let id: String
    let initialText: String
    /// Shown, not editable, and sent again with the edit.
    let images: [ImageData]
}

// MARK: - The editor

/// codeg web's `UserMessageEditor` as a sheet: the message's text in a field
/// that reads right to left for Hebrew or Arabic, its pictures as fixed chips
/// that go out again with it, the hint saying what saving does, and Cancel
/// and "Save & send". Save greys out with the reason while the edit can't
/// run; a failed save keeps the editor open with the text and says why.
struct MessageEditorSheet: View {
    let session: MessageEditSession
    /// Re-read as the session changes (a turn starting greys Save out).
    let availability: () -> MessageEditAvailability
    let keepOriginal: Bool
    /// Save: nil once the edit went out, else why it didn't.
    let onSave: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var text: String
    @State private var saving = false
    @State private var failure: String?

    init(session: MessageEditSession, availability: @escaping () -> MessageEditAvailability,
         keepOriginal: Bool, onSave: @escaping (String) async -> String?) {
        self.session = session
        self.availability = availability
        self.keepOriginal = keepOriginal
        self.onSave = onSave
        _text = State(initialValue: session.initialText)
    }

    var body: some View {
        let availability = availability()
        let target = availability.target ?? .fork(forkPointID: "", ready: true)
        let kind = MessageEditKind(target: target, keepOriginal: keepOriginal)
        let blocked: MessageEditBlock? = {
            if case .blocked(_, let block) = availability { return block }
            return nil
        }()
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.images.isEmpty
        let canSave = !saving && blocked == nil && availability != .hidden && hasContent

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !session.images.isEmpty {
                        imageChips
                    }
                    DirectionalTextView(text: $text, isEditable: !saving)
                        // Caret, selection and the field's own layout follow the text.
                        .environment(\.layoutDirection, TextDirection.detect(text) ?? layoutDirection)
                        .frame(minHeight: 140)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                        .hairlineBorder(Theme.Radius.md, color: Theme.hairline)
                        .accessibilityLabel(Text("Edit message"))
                    Text(verbatim: kind.hint)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let failure {
                        Label {
                            Text(verbatim: failure)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    actions(kind: kind, blocked: blocked, canSave: canSave)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(CodegBackground())
            .navigationTitle("Edit Message")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(saving)
    }

    private func actions(kind: MessageEditKind, blocked: MessageEditBlock?, canSave: Bool) -> some View {
        HStack(spacing: 10) {
            if let blocked, !saving {
                Text(verbatim: blocked.reason)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
                .disabled(saving)
            Button {
                save()
            } label: {
                HStack(spacing: 6) {
                    if saving { ProgressView().controlSize(.small) }
                    if saving {
                        Text(verbatim: kind.savingLabel)
                    } else {
                        Text("Save & send")
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(!canSave)
        }
    }

    private var imageChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(session.images.enumerated()), id: \.offset) { index, image in
                        EditImageChip(image: image, name: String(localized: "Image \(index + 1)"))
                    }
                }
            }
            Text("Attached images are sent again with the edited message")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        failure = nil
        let edited = text
        Task {
            let error = await onSave(edited)
            saving = false
            if let error {
                failure = error
            } else {
                dismiss()
            }
        }
    }
}

/// One of the message's pictures, as a fixed chip in the editor.
private struct EditImageChip: View {
    let image: ImageData
    let name: String
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Theme.surfaceNested
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(verbatim: name)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .hairlineBorder(7)
        .task {
            let key = TranscriptImages.key(for: image)
            thumbnail = TranscriptImages.cached(key)
            if thumbnail == nil { thumbnail = await TranscriptImages.decode(base64: image.data, maxPixelSize: 96) }
        }
    }
}

// MARK: - The text field

/// A multi-line text field that follows its text's direction, as codeg web's
/// editor does (`dir={detectTextDirection(text)}`): a Hebrew or Arabic
/// message is right-aligned and laid out right to left whatever the app's
/// language; an English one left to right; text with no letters takes the
/// natural direction. The caret starts at the end, the way the message was
/// left.
struct DirectionalTextView: UIViewRepresentable {
    @Binding var text: String
    var isEditable = true

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.text = text
        Self.applyDirection(to: view, text: text)
        // Once the sheet is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard view.window != nil else { return }
            view.becomeFirstResponder()
            let end = view.endOfDocument
            view.selectedTextRange = view.textRange(from: end, to: end)
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        if view.text != text {
            view.text = text
            Self.applyDirection(to: view, text: text)
        }
        view.isEditable = isEditable
    }

    /// The whole text's direction, from its words (``TextDirection``).
    static func direction(of text: String) -> LayoutDirection? {
        TextDirection.detect(text)
    }

    static func applyDirection(to view: UITextView, text: String) {
        let direction = Self.direction(of: text)
        let writing: NSWritingDirection
        let alignment: NSTextAlignment
        switch direction {
        case .rightToLeft?:
            writing = .rightToLeft
            alignment = .right
        case .leftToRight?:
            writing = .leftToRight
            alignment = .left
        default:
            writing = .natural
            alignment = .natural
        }
        // The view's own alignment first: setting it rewrites the paragraph
        // style, which then gets the writing direction on top. (Its layout
        // direction comes from SwiftUI's environment, set by the editor.)
        view.textAlignment = alignment
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = writing
        style.alignment = alignment
        if view.textStorage.length > 0 {
            view.textStorage.addAttribute(.paragraphStyle, value: style,
                                          range: NSRange(location: 0, length: view.textStorage.length))
        }
        view.typingAttributes[.paragraphStyle] = style
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        private var direction: LayoutDirection?

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ view: UITextView) {
            text.wrappedValue = view.text
            let now = DirectionalTextView.direction(of: view.text)
            if now != direction {
                direction = now
                DirectionalTextView.applyDirection(to: view, text: view.text)
            }
        }
    }
}
