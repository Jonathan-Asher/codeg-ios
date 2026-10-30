import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - What a pasted item is

/// What one pasted item becomes: text, which the field pastes as it always
/// has, or a file, attached the way one picked in Files is.
enum PastedItemKind: Equatable, Sendable {
    case text
    /// A file: the representation to load and the name it is attached under.
    case file(typeIdentifier: String, name: String)

    var isFile: Bool {
        if case .file = self { return true }
        return false
    }
}

/// Reads a pasted item (a pasteboard item, or one dropped on the field) by
/// its types, richest first, and the name it came with. A picture, a video,
/// an audio file or a PDF is a file even with text beside it (a file copied
/// in Files or Safari may bring its name or link as text). Any other document
/// is a file when it is named, or when nothing in it reads as text: the
/// format a word processor or a spreadsheet puts above the text of a
/// selection is the app's own, and that selection pastes as text.
enum PasteRouting {
    /// What the composer takes from the pasteboard: text as before, and any
    /// file.
    static let acceptedTypes: [UTType] = [.plainText, .text, .url, .image, .movie, .audio, .pdf, .data]

    static func kind(of provider: NSItemProvider) -> PastedItemKind {
        kind(typeIdentifiers: provider.registeredTypeIdentifiers, suggestedName: provider.suggestedName)
    }

    static func kind(typeIdentifiers: [String], suggestedName: String?) -> PastedItemKind {
        let types: [(id: String, type: UTType)] = typeIdentifiers.compactMap { id in
            guard let type = UTType(id), !type.isDynamic else { return nil }
            return (id, type)
        }
        let name = cleanName(suggestedName)
        // A file that came with its name, carrying the type its name says.
        if let name, let named = namedType(name, among: types) {
            return .file(typeIdentifier: named.id, name: fileName(name, for: named.type))
        }
        // The richest representation that says text or a picture, a video,
        // an audio file or a PDF.
        for (id, type) in types {
            if isTextual(type) { return .text }
            if isMedia(type) { return .file(typeIdentifier: id, name: fileName(name, for: type)) }
        }
        // Nothing reads as text: the first document type.
        for (id, type) in types where isDocument(type) {
            return .file(typeIdentifier: id, name: fileName(name, for: type))
        }
        return .text
    }

    /// The name a pasted file goes by: the one it came with (its extension
    /// made to match what is loaded), or "Pasted image.png" and the like.
    static func fileName(_ suggested: String?, for type: UTType) -> String {
        let ext = type.preferredFilenameExtension ?? ""
        var base = defaultBaseName(for: type)
        if let suggested = cleanName(suggested) {
            let current = (suggested as NSString).pathExtension
            if !current.isEmpty, let currentType = UTType(filenameExtension: current), !currentType.isDynamic {
                if currentType.conforms(to: type) { return suggested }
                base = (suggested as NSString).deletingPathExtension
            } else {
                base = suggested
            }
            if base.isEmpty { base = defaultBaseName(for: type) }
        }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    // MARK: Types

    /// Types too general to say what a file is.
    private static let generalTypes: Set<UTType> = [.item, .content, .data, .text, .compositeContent]

    /// Text as an app copies it: plain or rich text, a link, a web archive.
    /// Not a file's own address, which comes beside the file: the file's
    /// type decides.
    private static func isTextual(_ type: UTType) -> Bool {
        if type.conforms(to: .fileURL) { return false }
        return type.conforms(to: .text) || type.conforms(to: .url)
            || type.conforms(to: .rtfd) || type.conforms(to: .flatRTFD) || type.conforms(to: .webArchive)
    }

    /// A file whatever comes with it.
    private static func isMedia(_ type: UTType) -> Bool {
        type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .audio) || type.conforms(to: .pdf)
    }

    private static func isDocument(_ type: UTType) -> Bool {
        guard !generalTypes.contains(type), !type.conforms(to: .url), !isTextual(type) else { return false }
        return type.conforms(to: .data) || type.conforms(to: .content)
    }

    /// The item's representation of the type its name says (or one that
    /// type is a kind of), when it has one.
    private static func namedType(_ name: String,
                                   among types: [(id: String, type: UTType)]) -> (id: String, type: UTType)? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let named = UTType(filenameExtension: ext), !named.isDynamic else { return nil }
        if let exact = types.first(where: { $0.type == named }) { return exact }
        return types.first { named.conforms(to: $0.type) && !generalTypes.contains($0.type) }
    }

    private static func defaultBaseName(for type: UTType) -> String {
        if type.conforms(to: .image) { return "Pasted image" }
        if type.conforms(to: .movie) { return "Pasted video" }
        if type.conforms(to: .audio) { return "Pasted audio" }
        return "Pasted document"
    }

    /// A name that can be a file's: no folders in it, not hidden.
    private static func cleanName(_ name: String?) -> String? {
        guard let name else { return nil }
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 120 {
            let ext = (cleaned as NSString).pathExtension
            let stem = String((cleaned as NSString).deletingPathExtension.prefix(100))
            cleaned = ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// One paste, item by item: the files go in as long as there are free
/// attachment slots, in the order they were pasted; any text beside a file
/// is that file's name or link, so the text is pasted only when no file came.
struct PastePlan: Equatable, Sendable {
    /// The items that are attached.
    let files: [Int]
    /// Files left out: no free slot.
    let overLimit: Int
    /// The text items are pasted as text.
    let pastesText: Bool

    init(kinds: [PastedItemKind], freeSlots: Int) {
        let fileItems = kinds.indices.filter { kinds[$0].isFile }
        files = Array(fileItems.prefix(max(0, freeSlots)))
        overLimit = fileItems.count - files.count
        pastesText = fileItems.isEmpty
    }
}

/// The free attachment slots of one paste, taken as its files arrive.
struct PasteBudget: Equatable, Sendable {
    let free: Int
    private(set) var taken = 0
    private(set) var overLimit = 0

    init(free: Int) {
        self.free = max(0, free)
    }

    /// Whether one more file fits.
    mutating func take() -> Bool {
        guard taken < free else {
            overLimit += 1
            return false
        }
        taken += 1
        return true
    }
}

/// Text pasted where the cursor is, over what is selected.
enum PastedText {
    /// `selection` counts UTF-16 units, as ``DictationText/utf16Range(of:in:)``
    /// gives it; nil pastes at the end. Returns the text and the cursor after
    /// what was pasted.
    static func insert(_ pasted: String, into text: String, selection: Range<Int>?) -> (text: String, cursor: Int) {
        let current = text as NSString
        let lower = min(max(0, selection?.lowerBound ?? current.length), current.length)
        let upper = min(max(lower, selection?.upperBound ?? current.length), current.length)
        let result = current.replacingCharacters(in: NSRange(location: lower, length: upper - lower), with: pasted)
        return (result, lower + (pasted as NSString).length)
    }
}

// MARK: - Taking pasted items in

/// Takes in what is pasted into one composer, by ⌘V, the field's Paste or the
/// Paste button: each file is copied into the app's own folder, as one from
/// Files is, and goes the same way: a picture rides in the prompt, a video,
/// an audio file or a document is uploaded. The items of one paste arrive
/// together, so the free attachment slots are shared out among them.
@MainActor
final class ComposePasteIntake {
    /// Where the files and the text go: the composer's own handlers, set on
    /// each render.
    struct Sink {
        var freeSlots: () -> Int = { 0 }
        var addPictures: ([Attachment]) -> Void = { _ in }
        var addMedia: (AttachmentSource) -> Void = { _ in }
        var notice: (String) -> Void = { _ in }
        var insertText: (String) -> Void = { _ in }
    }

    var sink = Sink()

    /// The paste whose items are arriving.
    private var receiving: Batch?
    /// Files taken but not handed over yet.
    private var inFlight = 0

    private final class Batch {
        var budget: PasteBudget
        var expected = 0
        var loaded: [Int: URL?] = [:]
        var names: [Int: String] = [:]
        var sealed = false
        var delivered = false

        init(budget: PasteBudget) {
            self.budget = budget
        }

        var isComplete: Bool { sealed && loaded.count == expected }
    }

    /// The Paste button's items, all at once: the files are attached, and
    /// the text is pasted at the cursor when no file came with it.
    func receive(_ providers: [NSItemProvider]) {
        let kinds = providers.map(PasteRouting.kind(of:))
        let plan = PastePlan(kinds: kinds, freeSlots: Int.max)
        guard plan.pastesText else {
            for index in plan.files {
                if case .file(let type, let name) = kinds[index] {
                    receiveFile(providers[index], typeIdentifier: type, name: name)
                }
            }
            return
        }
        Self.loadText(providers) { [weak self] text in
            guard !text.isEmpty else { return }
            self?.sink.insertText(text)
        }
    }

    /// One file of the paste being made. Its loading starts at once: what is
    /// pasted can be read during the paste.
    func receiveFile(_ provider: NSItemProvider, typeIdentifier: String, name: String) {
        let batch = currentBatch()
        guard batch.budget.take() else { return }
        let index = batch.expected
        batch.expected += 1
        batch.names[index] = name
        inFlight += 1
        Self.copy(provider, typeIdentifier: typeIdentifier, name: name) { url in
            Task { @MainActor in self.loaded(url, index: index, in: batch) }
        }
    }

    private func currentBatch() -> Batch {
        if let receiving, !receiving.sealed { return receiving }
        let batch = Batch(budget: PasteBudget(free: sink.freeSlots() - inFlight))
        receiving = batch
        // Everything one paste brings arrives before the main queue turns.
        Task { @MainActor [weak self] in self?.seal(batch) }
        return batch
    }

    private func seal(_ batch: Batch) {
        batch.sealed = true
        if receiving === batch { receiving = nil }
        deliverIfComplete(batch)
    }

    private func loaded(_ url: URL?, index: Int, in batch: Batch) {
        inFlight = max(0, inFlight - 1)
        batch.loaded[index] = url
        deliverIfComplete(batch)
    }

    private func deliverIfComplete(_ batch: Batch) {
        guard batch.isComplete, !batch.delivered else { return }
        batch.delivered = true
        Task { await self.deliver(batch) }
    }

    /// As ``ComposeBar``'s Files intake does it: the pictures together, a
    /// picture the iPhone can't read as a document, and what didn't fit or
    /// couldn't be read said in a notice.
    private func deliver(_ batch: Batch) async {
        var pictures: [Attachment] = []
        var unreadable: [String] = []
        for index in 0..<batch.expected {
            guard let url = batch.loaded[index] ?? nil else {
                unreadable.append(batch.names[index] ?? "")
                continue
            }
            switch PickedFileRoute.route(forFileNamed: url.lastPathComponent) {
            case .picture:
                let picture = await Task.detached(priority: .userInitiated) {
                    AttachmentPrep.make(fromFile: url)
                }.value
                if let picture {
                    pictures.append(picture)
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                } else {
                    sink.addMedia(.file(url))
                }
            case .upload, .folder, .package:
                sink.addMedia(.file(url))
            }
        }
        if !pictures.isEmpty { sink.addPictures(pictures) }
        if let name = unreadable.first {
            sink.notice("\(name) couldn't be read.")
        }
        if batch.budget.overLimit > 0 {
            sink.notice("You can attach up to \(AttachmentPrep.maxCount) files.")
        }
    }

    /// The item's file, copied into a folder of the app's own under `name`
    /// (the loaded file is gone once the handler returns). Nil when it
    /// couldn't be read.
    nonisolated static func copy(_ provider: NSItemProvider, typeIdentifier: String, name: String,
                                 completion: @escaping @Sendable (URL?) -> Void) {
        _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
            guard let url else {
                completion(nil)
                return
            }
            let folder = VideoAttachmentPrep.workDirectory()
            let destination = folder.appendingPathComponent(name)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                completion(destination)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                completion(nil)
            }
        }
    }

    /// The items' text, in order (a link as its address).
    private static func loadText(_ providers: [NSItemProvider], completion: @escaping @MainActor (String) -> Void) {
        let parts = TextParts(count: providers.count)
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            if provider.canLoadObject(ofClass: String.self) {
                group.enter()
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    parts.set(text, at: index)
                    group.leave()
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    parts.set(url?.absoluteString, at: index)
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let text = parts.joined()
            Task { @MainActor in completion(text) }
        }
    }

    private final class TextParts: @unchecked Sendable {
        private let lock = NSLock()
        private var parts: [String?]

        init(count: Int) {
            parts = Array(repeating: nil, count: count)
        }

        func set(_ text: String?, at index: Int) {
            lock.lock()
            parts[index] = text
            lock.unlock()
        }

        func joined() -> String {
            lock.lock()
            defer { lock.unlock() }
            return parts.compactMap { $0 }.joined()
        }
    }
}

// MARK: - The field's paste

/// The message field's paste delegate: a pasted (or dropped) file is taken
/// by the composer's ``ComposePasteIntake`` instead of the field, and the
/// text that comes beside it (its name or link) is left out. Text alone
/// pastes as it always did.
@MainActor
final class ComposeTextPasteDelegate: NSObject, UITextPasteDelegate {
    weak var intake: ComposePasteIntake?
    /// The delegate the field had, which goes on handling text.
    weak var forward: UITextPasteDelegate?
    /// A file came in the paste being made (the pasteboard's change count
    /// then, and when).
    private var fileInPaste: (changeCount: Int, at: Date)?

    func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: UITextPasteConfigurationSupporting,
                                          transform item: UITextPasteItem) {
        let provider = item.itemProvider
        if let intake, case .file(let type, let name) = PasteRouting.kind(of: provider) {
            fileInPaste = (UIPasteboard.general.changeCount, Date())
            intake.receiveFile(provider, typeIdentifier: type, name: name)
            item.setNoResult()
            return
        }
        if forward?.textPasteConfigurationSupporting?(textPasteConfigurationSupporting, transform: item) == nil {
            item.setDefaultResult()
        }
    }

    func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: UITextPasteConfigurationSupporting,
                                          combineItemAttributedStrings itemStrings: [NSAttributedString],
                                          for textRange: UITextRange) -> NSAttributedString {
        let filed = fileInPaste.map { paste in
            paste.changeCount == UIPasteboard.general.changeCount && Date().timeIntervalSince(paste.at) < 5
        } ?? false
        fileInPaste = nil
        if filed { return NSAttributedString() }
        if let combined = forward?.textPasteConfigurationSupporting?(
            textPasteConfigurationSupporting, combineItemAttributedStrings: itemStrings, for: textRange) {
            return combined
        }
        let combined = NSMutableAttributedString()
        for string in itemStrings { combined.append(string) }
        return combined
    }

    /// What the field accepts: what it took before, and any file.
    static func pasteConfiguration(adding existing: UIPasteConfiguration?) -> UIPasteConfiguration {
        var identifiers = existing?.acceptableTypeIdentifiers
            ?? UIPasteConfiguration(forAccepting: NSString.self).acceptableTypeIdentifiers
        for type in PasteRouting.acceptedTypes where !identifiers.contains(type.identifier) {
            identifiers.append(type.identifier)
        }
        return UIPasteConfiguration(acceptableTypeIdentifiers: identifiers)
    }
}

/// Sits behind the message field and gives the field's text view (the one
/// SwiftUI makes for it) the composer's paste: Paste and ⌘V offered for a
/// file too, and the file attached.
struct ComposePasteHook: UIViewRepresentable {
    let intake: ComposePasteIntake
    let sink: ComposePasteIntake.Sink

    func makeUIView(context: Context) -> ComposePasteProbe {
        let probe = ComposePasteProbe()
        probe.pasteHandler.intake = intake
        return probe
    }

    func updateUIView(_ probe: ComposePasteProbe, context: Context) {
        intake.sink = sink
        probe.pasteHandler.intake = intake
        probe.attach()
    }
}

/// An empty view the size of the message field that finds the field's text
/// view: the editable one under it, nearest to it.
final class ComposePasteProbe: UIView {
    let pasteHandler = ComposeTextPasteDelegate()
    private(set) weak var textView: UITextView?
    /// Looks that found no text view, so a field SwiftUI draws some other
    /// way isn't searched for on every layout.
    private var misses = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        misses = 0
        attach()
        // The field's own view may come after this one.
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attach()
    }

    func attach() {
        guard window != nil else { return }
        if let textView, textView.window != nil, textView.pasteDelegate === pasteHandler { return }
        guard misses < 40 else { return }
        guard let found = Self.findTextView(near: self) else {
            misses += 1
            return
        }
        misses = 0
        if found.pasteDelegate !== pasteHandler {
            pasteHandler.forward = found.pasteDelegate
            found.pasteDelegate = pasteHandler
        }
        let configuration = ComposeTextPasteDelegate.pasteConfiguration(adding: found.pasteConfiguration)
        if found.pasteConfiguration?.acceptableTypeIdentifiers != configuration.acceptableTypeIdentifiers {
            found.pasteConfiguration = configuration
        }
        textView = found
    }

    /// The editable text view under `probe`'s middle, looked for in the
    /// views around it, nearest first.
    static func findTextView(near probe: UIView) -> UITextView? {
        guard let window = probe.window else { return nil }
        let frame = probe.convert(probe.bounds, to: window)
        guard frame.width > 1, frame.height > 1 else { return nil }
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        var ancestor = probe.superview
        var level = 0
        while let current = ancestor, level < 12 {
            var best: (view: UITextView, distance: CGFloat)?
            for candidate in editableTextViews(in: current) {
                let box = candidate.convert(candidate.bounds, to: window)
                guard box.insetBy(dx: -12, dy: -12).contains(middle) else { continue }
                let distance = hypot(box.midX - middle.x, box.midY - middle.y)
                if best.map({ distance < $0.distance }) ?? true { best = (candidate, distance) }
            }
            if let best { return best.view }
            ancestor = current.superview
            level += 1
        }
        return nil
    }

    private static func editableTextViews(in root: UIView) -> [UITextView] {
        var found: [UITextView] = []
        var queue: [UIView] = [root]
        var next = 0
        while next < queue.count, next < 800 {
            let view = queue[next]
            next += 1
            if let textView = view as? UITextView, textView.isEditable {
                found.append(textView)
            }
            queue.append(contentsOf: view.subviews)
        }
        return found
    }
}
