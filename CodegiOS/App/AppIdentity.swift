import Foundation

/// The app's identity as configured in `Config/Identity.xcconfig`, read back
/// from Info.plist so code never hard-codes the name or the URL scheme.
enum AppIdentity {
    /// The home-screen name (`CFBundleDisplayName`).
    static let displayName: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? "Codeg"

    /// The registered deep-link scheme, lowercased (e.g. `codegplus`).
    static let urlScheme: String =
        ((Bundle.main.object(forInfoDictionaryKey: "CodegURLScheme") as? String) ?? "codegplus")
            .lowercased()

    /// Whether `url` is one of this app's own deep links.
    static func owns(_ url: URL) -> Bool {
        url.scheme?.lowercased() == urlScheme
    }
}
