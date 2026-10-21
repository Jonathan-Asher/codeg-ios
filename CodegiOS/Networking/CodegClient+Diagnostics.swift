import Foundation

// Crash reports for the codeg fork's `report_client_diagnostic` (see
// `Diagnostics`). The body is built by the caller: the report's JSON as-is.

/// The server's answer: the stored report's id.
struct ClientDiagnosticReceipt: Decodable, Sendable {
    let id: String
    let stored: Bool
}

extension CodegClient {
    /// Hand one report (`{"report": …}`) to the server. Throws unless the
    /// server says it stored it, so a proxy's stray 200 never counts.
    @discardableResult
    func reportClientDiagnostic(_ body: Data) async throws -> ClientDiagnosticReceipt {
        let data = try await send("report_client_diagnostic", rawBody: body)
        let receipt: ClientDiagnosticReceipt
        do { receipt = try CodegJSON.decoder.decode(ClientDiagnosticReceipt.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
        guard receipt.stored else { throw APIError.decoding("the server did not store the report") }
        return receipt
    }
}
