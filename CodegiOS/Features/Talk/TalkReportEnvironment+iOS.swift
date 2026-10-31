import Foundation

extension TalkReportEnvironment {
    /// This app and this iPhone: the app's version, build and bundle id, the
    /// model (`iPhone17,2`) and the iOS version.
    static var current: TalkReportEnvironment {
        let info = Bundle.main.infoDictionary ?? [:]
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return TalkReportEnvironment(
            app: ["version": info["CFBundleShortVersionString"] as? String ?? "?",
                  "build": info["CFBundleVersion"] as? String ?? "?",
                  "bundleId": Bundle.main.bundleIdentifier ?? "?"],
            device: ["model": model,
                     "os": "iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"])
    }
}
