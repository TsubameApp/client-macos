import Foundation

struct AppBuildInfo: Equatable, Sendable {
    let marketingVersion: String
    let buildNumber: String
    let displayVersion: String
    let commit: String?
    let isDirty: Bool

    static let current = AppBuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])

    static var configurationName: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    init(infoDictionary: [String: Any]) {
        let marketingVersion = infoDictionary["CFBundleShortVersionString"] as? String
            ?? "0.0.0"
        self.marketingVersion = marketingVersion
        buildNumber = infoDictionary["CFBundleVersion"] as? String ?? "unknown"
        displayVersion = infoDictionary["TsubameDisplayVersion"] as? String
            ?? marketingVersion
        commit = infoDictionary["TsubameGitCommit"] as? String
        isDirty = infoDictionary["TsubameGitDirty"] as? Bool ?? false
    }
}
