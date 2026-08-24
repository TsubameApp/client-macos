import Foundation
import OSLog
import TsubameCore

protocol DictionaryLookingUp: Sendable {
    func lookup(
        text: String,
        position: Int,
        requestID: UInt64
    ) async throws -> LookupResult
}

actor DictionaryEngine: DictionaryLookingUp {
    private let scopedAccess: SecurityScopedAccess
    private let lookupService: DictionaryLookup

    init(databaseURL: URL) throws {
        let scopedAccess = SecurityScopedAccess(url: databaseURL)
        let store = try SQLiteDictionaryStore(databaseURL: databaseURL)
        self.scopedAccess = scopedAccess
        lookupService = DictionaryLookup(store: store)
    }

    func lookup(
        text: String,
        position: Int,
        requestID: UInt64
    ) async throws -> LookupResult {
        try Task.checkCancellation()
        let signpostID = TsubameLogging.signposter.makeSignpostID()
        let interval = TsubameLogging.signposter.beginInterval("Lookup", id: signpostID)
        defer {
            TsubameLogging.signposter.endInterval("Lookup", interval)
        }

        TsubameLogging.lookup.debug(
            "request=\(requestID, privacy: .public) lookup started bytes=\(text.utf8.count, privacy: .public) position=\(position, privacy: .public)"
        )
        let request = try PositionedLookupRequest(
            text: text,
            position: position,
            resultLimit: 100
        )
        let result = try lookupService.lookup(request)
        try Task.checkCancellation()
        TsubameLogging.lookup.notice(
            "request=\(requestID, privacy: .public) lookup completed entries=\(result.entries.count, privacy: .public) range=\(result.sourceRange.start, privacy: .public)..<\(result.sourceRange.end, privacy: .public)"
        )
        return result
    }
}

private final class SecurityScopedAccess: @unchecked Sendable {
    private let url: URL
    private let isActive: Bool

    init(url: URL) {
        self.url = url
        isActive = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if isActive {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
