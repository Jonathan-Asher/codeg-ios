import Foundation
import Observation

/// A session's side questions (`/btw`, see ``SideQuestionCommand``): asking,
/// the panel above the message bar (a sheet on iPhone) and its actions.
/// Nothing here touches the transcript, the queue or the running turn.
@MainActor
@Observable
final class SideQuestionModel {
    enum Status: Equatable {
        case pending
        case answered(SideQuestionRecord)
        /// Why, in words the user can read.
        case failed(String)
    }

    struct Entry: Identifiable, Equatable {
        /// The stored exchange's id (`sq-12`), or a local one while it is on
        /// its way.
        let id: String
        let question: String
        var status: Status

        var record: SideQuestionRecord? {
            if case .answered(let record) = status { return record }
            return nil
        }
    }

    /// Where a question goes: the screen's live connection, when it has one,
    /// and its conversation.
    struct Target: Equatable {
        var connectionId: String?
        var conversationId: Int?
    }

    /// Oldest first.
    private(set) var entries: [Entry] = []
    /// The entry on screen.
    private(set) var index = 0
    private(set) var isOpen = false

    var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }

    /// The newest target, read when a question goes out, so an answer that
    /// takes a while never pins a stale connection.
    @ObservationIgnored var target: () -> Target = { Target() }
    /// The server can't answer side questions for this session after all:
    /// the question is gone from the panel and handed back.
    @ObservationIgnored var onUnsupported: (String) -> Void = { _ in }

    @ObservationIgnored private let client: CodegClient
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    /// The conversation whose stored exchanges are in `entries`.
    @ObservationIgnored private var historyLoadedFor: Int?
    @ObservationIgnored private var serial = 0

    init(client: CodegClient) {
        self.client = client
    }

    /// `/btw <question>`: ask it, shown at once as waiting.
    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            reopen()
            return
        }
        serial += 1
        let id = "local-\(serial)"
        entries.append(Entry(id: id, question: question, status: .pending))
        index = entries.count - 1
        isOpen = true
        loadHistory()
        send(id)
    }

    /// `/btw` alone: the panel again, on the newest exchange.
    func reopen() {
        isOpen = true
        index = max(entries.count - 1, 0)
        loadHistory()
    }

    func close() {
        isOpen = false
    }

    /// Step to an earlier (-1) or later (+1) exchange.
    func step(_ delta: Int) {
        guard !entries.isEmpty else { return }
        index = min(max(index + delta, 0), entries.count - 1)
    }

    /// Stop waiting for an answer: the question leaves the panel. The server
    /// may still finish it and keep it with the conversation's side questions.
    func cancel(_ id: String) {
        tasks.removeValue(forKey: id)?.cancel()
        remove(id)
    }

    /// Ask a question that failed again.
    func retry(_ id: String) {
        guard let at = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[at].status = .pending
        index = at
        send(id)
    }

    func teardown() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        historyTask?.cancel()
        historyTask = nil
    }

    // MARK: - Requests

    private func send(_ id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let target = target()
        let client = client
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            let outcome: Result<SideQuestionRecord, Error>
            do {
                outcome = .success(try await client.askSideQuestion(
                    connectionId: target.connectionId, conversationId: target.conversationId,
                    question: entry.question))
            } catch {
                outcome = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.settle(id, outcome)
        }
    }

    private func settle(_ id: String, _ outcome: Result<SideQuestionRecord, Error>) {
        tasks[id] = nil
        guard let at = entries.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .success(let record):
            // The stored exchanges, fetched while this one was on its way,
            // may already hold it: keep that one and drop the stand-in.
            if let stored = record.id,
               let twin = entries.firstIndex(where: { $0.id != id && $0.record?.id == stored }) {
                let shown = index == at ? twin : index
                entries.remove(at: at)
                index = min(max(shown > at ? shown - 1 : shown, 0), max(entries.count - 1, 0))
            } else {
                entries[at].status = .answered(record)
            }
        case .failure(let error as APIError) where error.isSideQuestionUnsupported:
            let question = entries[at].question
            remove(id)
            onUnsupported(question)
        case .failure(let error):
            entries[at].status = .failed(Self.message(for: error))
        }
    }

    /// The server's own words where it gave any (a timeout, the agent's
    /// failure), else what went wrong on the way.
    static func message(for error: Error) -> String {
        if let error = error as? APIError {
            switch error {
            case .server(_, _, let message) where !message.isEmpty:
                return message
            case .server:
                break
            default:
                return error.errorDescription ?? String(localized: "The side question couldn’t be answered.")
            }
        }
        return String(localized: "The side question couldn’t be answered.")
    }

    /// The conversation's stored exchanges, fetched once: they go before
    /// anything asked since, without repeating one already here. A fetch
    /// that fails (no network, an older server) is tried again next time.
    private func loadHistory() {
        guard let conversationId = target().conversationId, historyLoadedFor != conversationId,
              historyTask == nil else { return }
        let client = client
        historyTask = Task { [weak self] in
            let records = try? await client.sideQuestions(conversationId: conversationId)
            guard !Task.isCancelled, let self else { return }
            self.historyTask = nil
            guard let records else { return }
            self.historyLoadedFor = conversationId
            self.merge(history: records)
        }
    }

    func merge(history records: [SideQuestionRecord]) {
        let known = Set(entries.compactMap { $0.record?.id })
        let stored = records.enumerated().compactMap { offset, record -> Entry? in
            if let id = record.id, known.contains(id) { return nil }
            return Entry(id: record.id.map { "sq-\($0)" } ?? "stored-\(offset)", question: record.question,
                         status: .answered(record))
        }
        guard !stored.isEmpty else { return }
        let hadEntries = !entries.isEmpty
        entries = stored + entries
        // The same exchange stays on screen (it moved by what went before
        // it); an empty panel shows the newest stored one.
        index = hadEntries ? index + stored.count : entries.count - 1
    }

    private func remove(_ id: String) {
        guard let at = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: at)
        guard !entries.isEmpty else {
            index = 0
            isOpen = false
            return
        }
        if index > at { index -= 1 }
        index = min(index, entries.count - 1)
    }
}

/// Which agents answered side questions on each server, as their live
/// sessions said (or the server refused): what a session with no live
/// connection goes by. Keyed by server, like ``ForkCapabilities``.
@MainActor
final class SideQuestionCapabilities {
    static let shared = SideQuestionCapabilities()

    /// Server key → agent wire value → answers.
    private var byServer: [String: [String: Bool]] = [:]

    func answers(_ agent: AgentType, client: CodegClient) -> Bool? {
        byServer[TranscriptCache.serverKey(for: client)]?[agent.wireValue]
    }

    func note(agent: AgentType, answers supported: Bool, client: CodegClient) {
        byServer[TranscriptCache.serverKey(for: client), default: [:]][agent.wireValue] = supported
    }
}
