import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Codeg

/// Pasting into the composer: what a pasted item is read as (text, or a file
/// routed as one from Files is: a picture inline, a video, an audio file or
/// a document uploaded), the attachment slots one paste shares out, the
/// field's paste delegate, and the message field on the simulator taking a
/// pasted PDF.
@MainActor
final class ComposePasteTests: XCTestCase {
    private func kind(_ types: [String], name: String? = nil) -> PastedItemKind {
        PasteRouting.kind(typeIdentifiers: types, suggestedName: name)
    }

    /// Where a pasted file goes once it is copied under its name.
    private func route(_ kind: PastedItemKind) -> PickedFileRoute? {
        guard case .file(_, let name) = kind else { return nil }
        return PickedFileRoute.route(forFileNamed: name)
    }

    // MARK: - What an item is

    func testAPictureRidesInThePrompt() {
        let photo = kind(["public.heic", "public.jpeg"], name: "IMG_0001.HEIC")
        XCTAssertEqual(photo, .file(typeIdentifier: "public.heic", name: "IMG_0001.HEIC"))
        XCTAssertEqual(route(photo), .picture)
        // From a browser: the image above its address.
        let image = kind(["public.png", "public.url", "public.utf8-plain-text"])
        XCTAssertEqual(image, .file(typeIdentifier: "public.png", name: "Pasted image.png"))
        XCTAssertEqual(route(image), .picture)
    }

    func testAPDFIsUploadedAsADocument() {
        let pdf = kind(["com.adobe.pdf"], name: "Report.pdf")
        XCTAssertEqual(pdf, .file(typeIdentifier: "com.adobe.pdf", name: "Report.pdf"))
        XCTAssertEqual(route(pdf), .upload(.document))
        XCTAssertEqual(kind(["com.adobe.pdf"]), .file(typeIdentifier: "com.adobe.pdf", name: "Pasted document.pdf"))
    }

    func testAVideoAndAnAudioFileAreUploaded() {
        let video = kind(["com.apple.quicktime-movie"], name: "IMG_0002.MOV")
        XCTAssertEqual(video, .file(typeIdentifier: "com.apple.quicktime-movie", name: "IMG_0002.MOV"))
        XCTAssertEqual(route(video), .upload(.video))
        let unnamed = kind(["public.mpeg-4"])
        XCTAssertEqual(route(unnamed), .upload(.video))
        let audio = kind(["public.mp3"], name: "Voice memo.mp3")
        XCTAssertEqual(route(audio), .upload(.audio))
    }

    func testAnyOtherDocumentIsUploaded() {
        let word = kind(["org.openxmlformats.wordprocessingml.document"], name: "Brief.docx")
        XCTAssertEqual(word, .file(typeIdentifier: "org.openxmlformats.wordprocessingml.document", name: "Brief.docx"))
        XCTAssertEqual(route(word), .upload(.document))
        // Nothing in it reads as text: a file, named after its type.
        let zip = kind(["public.zip-archive"])
        XCTAssertEqual(zip, .file(typeIdentifier: "public.zip-archive", name: "Pasted document.zip"))
        // A text file copied in Files is the file, not its words.
        let config = kind(["public.json", "public.utf8-plain-text"], name: "config.json")
        XCTAssertEqual(config, .file(typeIdentifier: "public.json", name: "config.json"))
        XCTAssertEqual(route(config), .upload(.document))
    }

    func testTextAlonePastesAsText() {
        XCTAssertEqual(kind(["public.utf8-plain-text"]), .text)
        XCTAssertEqual(kind(["public.html", "public.rtf", "public.utf8-plain-text"]), .text, "rich text")
        XCTAssertEqual(kind(["public.url", "public.utf8-plain-text"]), .text, "a link")
        // A word processor's own format above the text of a selection: text.
        XCTAssertEqual(kind(["org.openxmlformats.wordprocessingml.document", "public.rtf",
                             "public.utf8-plain-text"]), .text)
        // A spreadsheet's selection with a picture of it below its text.
        XCTAssertEqual(kind(["public.html", "public.utf8-plain-text", "public.png"]), .text)
        XCTAssertEqual(kind([]), .text, "nothing the composer knows: the field decides")
    }

    func testAFileWithItsNameOrLinkAsTextIsTheFile() {
        // A file copied in Files: the file, its name as text.
        XCTAssertEqual(kind(["com.adobe.pdf", "public.utf8-plain-text"], name: "Report.pdf"),
                       .file(typeIdentifier: "com.adobe.pdf", name: "Report.pdf"))
        XCTAssertEqual(kind(["com.adobe.pdf", "public.file-url"]),
                       .file(typeIdentifier: "com.adobe.pdf", name: "Pasted document.pdf"))
        // A document named as a file, even beside text.
        XCTAssertEqual(kind(["org.openxmlformats.wordprocessingml.document", "public.utf8-plain-text"],
                            name: "Brief.docx"),
                       .file(typeIdentifier: "org.openxmlformats.wordprocessingml.document", name: "Brief.docx"))
        // One paste with a file and a separate text item: the file alone.
        let plan = PastePlan(kinds: [.file(typeIdentifier: "com.adobe.pdf", name: "Report.pdf"), .text], freeSlots: 10)
        XCTAssertEqual(plan.files, [0])
        XCTAssertFalse(plan.pastesText)
        XCTAssertTrue(PastePlan(kinds: [.text, .text], freeSlots: 10).pastesText)
    }

    func testANameIsMadeToMatchWhatIsLoaded() {
        XCTAssertEqual(PasteRouting.fileName("IMG_0001", for: .heic), "IMG_0001.heic")
        XCTAssertEqual(PasteRouting.fileName("photo.jpeg", for: .png), "photo.png")
        XCTAssertEqual(PasteRouting.fileName("Archive.v2", for: .zip), "Archive.v2.zip")
        XCTAssertEqual(PasteRouting.fileName("Q3/Q4 report.pdf", for: .pdf), "Q3-Q4 report.pdf")
        XCTAssertEqual(PasteRouting.fileName(".hidden.pdf", for: .pdf), "hidden.pdf")
        XCTAssertEqual(PasteRouting.fileName(nil, for: .mpeg4Movie), "Pasted video.mp4")
        XCTAssertEqual(PasteRouting.fileName("  ", for: .png), "Pasted image.png")
    }

    // MARK: - Free slots

    func testFilesOverTheFreeSlotsAreLeftOut() {
        let pdf = PastedItemKind.file(typeIdentifier: "com.adobe.pdf", name: "a.pdf")
        let plan = PastePlan(kinds: [pdf, .text, pdf, pdf], freeSlots: 2)
        XCTAssertEqual(plan.files, [0, 2], "in the order they were pasted")
        XCTAssertEqual(plan.overLimit, 1)
        XCTAssertEqual(PastePlan(kinds: [pdf], freeSlots: 0).overLimit, 1)

        var budget = PasteBudget(free: 1)
        XCTAssertTrue(budget.take())
        XCTAssertFalse(budget.take())
        XCTAssertEqual(budget.overLimit, 1)
        XCTAssertFalse(PasteBudget(free: -3).free > 0)
    }

    func testPastedTextGoesInAtTheCursor() {
        XCTAssertEqual(PastedText.insert("there", into: "Hello  world", selection: 6..<6).text, "Hello there world")
        let replaced = PastedText.insert("שלום", into: "Say hi now", selection: 4..<6)
        XCTAssertEqual(replaced.text, "Say שלום now")
        XCTAssertEqual(replaced.cursor, 8)
        XCTAssertEqual(PastedText.insert("!", into: "Done", selection: nil).text, "Done!")
    }

    // MARK: - Taking a pasted file in

    /// A composer's handlers, recording what reaches them.
    @MainActor
    private final class Received {
        var pictures: [Attachment] = []
        var media: [URL] = []
        var notices: [String] = []
        var text: [String] = []
    }

    private func intake(freeSlots: Int = 10) -> (ComposePasteIntake, Received) {
        let received = Received()
        let intake = ComposePasteIntake()
        intake.sink = ComposePasteIntake.Sink(
            freeSlots: { freeSlots },
            addPictures: { received.pictures += $0 },
            addMedia: { source in
                if case .file(let url) = source { received.media.append(url) }
            },
            notice: { received.notices.append($0) },
            insertText: { received.text.append($0) }
        )
        return (intake, received)
    }

    private func pdfProvider(name: String? = "Report.pdf") -> NSItemProvider {
        let provider = NSItemProvider(item: Data("%PDF-1.4 a pasted file".utf8) as NSData,
                                      typeIdentifier: UTType.pdf.identifier)
        provider.suggestedName = name
        return provider
    }

    func testAPastedPDFIsCopiedUnderItsNameAndUploaded() async {
        let (intake, received) = intake()
        intake.receive([pdfProvider()])
        let arrived = await eventually { received.media.count == 1 }
        XCTAssertTrue(arrived)
        let file = received.media.first
        XCTAssertEqual(file?.lastPathComponent, "Report.pdf")
        XCTAssertEqual(file.flatMap { try? Data(contentsOf: $0) }, Data("%PDF-1.4 a pasted file".utf8))
        XCTAssertTrue(received.text.isEmpty)
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }

    func testOnePasteSharesTheFreeSlots() async {
        let (intake, received) = intake(freeSlots: 2)
        intake.receive([pdfProvider(name: "a.pdf"), pdfProvider(name: "b.pdf"), pdfProvider(name: "c.pdf")])
        let arrived = await eventually { received.media.count == 2 && !received.notices.isEmpty }
        XCTAssertTrue(arrived)
        XCTAssertEqual(received.media.map(\.lastPathComponent), ["a.pdf", "b.pdf"])
        XCTAssertEqual(received.notices, ["You can attach up to \(AttachmentPrep.maxCount) files."])
        for file in received.media { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }

    func testThePasteButtonsTextGoesInAtTheCursor() async {
        let (intake, received) = intake()
        intake.receive([NSItemProvider(object: "a copied line" as NSString)])
        let arrived = await eventually { !received.text.isEmpty }
        XCTAssertTrue(arrived)
        XCTAssertEqual(received.text, ["a copied line"])
        XCTAssertTrue(received.media.isEmpty)
    }

    // MARK: - The field's paste delegate

    /// A pasted item as the field hands it to its paste delegate.
    @MainActor
    private final class PasteItem: NSObject, UITextPasteItem {
        let itemProvider: NSItemProvider
        let localObject: Any? = nil
        let defaultAttributes: [NSAttributedString.Key: Any] = [:]
        var result = "none"

        init(_ provider: NSItemProvider) {
            itemProvider = provider
        }

        func setStringResult(_ string: String) { result = "string" }
        func setAttributedStringResult(_ string: NSAttributedString) { result = "attributed" }
        func setAttachmentResult(_ textAttachment: NSTextAttachment) { result = "attachment" }
        func setNoResult() { result = "no result" }
        func setDefaultResult() { result = "default" }
    }

    func testTheFieldTakesTheFileAndLeavesOutItsName() async {
        let (intake, received) = intake()
        let delegate = ComposeTextPasteDelegate()
        delegate.intake = intake
        let field = UITextView()

        let provider = pdfProvider()
        provider.registerObject("Report.pdf" as NSString, visibility: .all)
        let file = PasteItem(provider)
        delegate.textPasteConfigurationSupporting(field, transform: file)
        XCTAssertEqual(file.result, "no result", "the field doesn't paste the file")
        let name = NSAttributedString(string: "Report.pdf")
        let pasted = delegate.textPasteConfigurationSupporting(field, combineItemAttributedStrings: [name],
                                                                for: field.textRange(from: field.endOfDocument,
                                                                                     to: field.endOfDocument)!)
        XCTAssertEqual(pasted.string, "", "the text that came with the file is left out")
        let arrived = await eventually { received.media.count == 1 }
        XCTAssertTrue(arrived)

        let text = PasteItem(NSItemProvider(object: "plain words" as NSString))
        delegate.textPasteConfigurationSupporting(field, transform: text)
        XCTAssertEqual(text.result, "default", "text pastes as before")
        let words = delegate.textPasteConfigurationSupporting(
            field, combineItemAttributedStrings: [NSAttributedString(string: "plain "), NSAttributedString(string: "words")],
            for: field.textRange(from: field.endOfDocument, to: field.endOfDocument)!)
        XCTAssertEqual(words.string, "plain words")
        for file in received.media { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }

    func testTheFieldAcceptsFilesBesideText() {
        let configuration = ComposeTextPasteDelegate.pasteConfiguration(adding: nil)
        let accepted = configuration.acceptableTypeIdentifiers
        XCTAssertTrue(accepted.contains(UTType.utf8PlainText.identifier) || accepted.contains(UTType.plainText.identifier))
        for type in [UTType.image, .movie, .audio, .pdf, .data] {
            XCTAssertTrue(accepted.contains(type.identifier), type.identifier)
        }
        let again = ComposeTextPasteDelegate.pasteConfiguration(adding: configuration)
        XCTAssertEqual(again.acceptableTypeIdentifiers, accepted, "nothing added twice")
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

    private func textViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews(in:))
    }

    private func settle(_ seconds: TimeInterval = 0.6) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The composer's field and another one: the paste goes to the
    /// composer's.
    private struct Fields: View {
        let intake: ComposePasteIntake
        let sink: ComposePasteIntake.Sink

        var body: some View {
            VStack(spacing: 40) {
                TextField("Answer", text: .constant(""), axis: .vertical)
                Spacer()
                TextField("Message", text: .constant(""), axis: .vertical)
                    .background(ComposePasteHook(intake: intake, sink: sink))
            }
            .padding(40)
        }
    }

    func testTheMessageFieldPastesAPDFItsTextViewWouldNotTake() async throws {
        let (intake, received) = intake()
        let window = try host(Fields(intake: intake, sink: intake.sink))
        defer { window.isHidden = true }
        settle()
        let fields = textViews(in: window).sorted { $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY }
        XCTAssertEqual(fields.count, 2)
        let message = try XCTUnwrap(fields.last)
        XCTAssertTrue(message.pasteDelegate is ComposeTextPasteDelegate, "the composer's field has the paste")
        XCTAssertFalse(fields.first?.pasteDelegate is ComposeTextPasteDelegate, "not the other field")
        XCTAssertTrue(message.pasteConfiguration?.acceptableTypeIdentifiers.contains(UTType.pdf.identifier) ?? false)

        // A PDF on the pasteboard, as Files puts one there.
        UIPasteboard.general.setItemProviders([pdfProvider()], localOnly: true, expirationDate: nil)
        message.becomeFirstResponder()
        settle(0.3)
        XCTAssertTrue(message.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil),
                      "Paste is offered for a file")
        UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.paste(_:)), to: message,
                                        from: nil, for: nil)
        let arrived = await eventually { received.media.count == 1 }
        XCTAssertTrue(arrived, "the PDF is attached")
        XCTAssertEqual(received.media.first?.pathExtension, "pdf")
        XCTAssertEqual(message.text, "", "nothing pasted as text")
        for file in received.media { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        UIPasteboard.general.items = []
    }
}
