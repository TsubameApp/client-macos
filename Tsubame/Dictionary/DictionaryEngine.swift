import Foundation
import OSLog
import TsubameCore

protocol DictionaryLookingUp: Sendable {
    func lookup(
        text: String,
        position: Int,
        requestID: UInt64
    ) async throws -> DictionaryLookupResult
}

struct DictionaryLookupEntry: Sendable, Equatable, Identifiable {
    struct ID: Sendable, Equatable, Hashable {
        let dictionaryID: UUID
        let entryID: Int64
    }

    let dictionaryID: UUID
    let dictionaryTitle: String
    let sourceRange: UTF8TextRange
    let entry: DictionaryEntry

    var id: ID { ID(dictionaryID: dictionaryID, entryID: entry.id) }
}

struct DictionaryLookupResult: Sendable, Equatable {
    let entries: [DictionaryLookupEntry]
}

actor DictionaryEngine: DictionaryLookingUp {
    private let dictionaryID: UUID
    private let dictionaryTitle: String
    private let scopedAccess: SecurityScopedAccess
    private let lookupService: DictionaryLookup

    init(dictionaryID: UUID, dictionaryTitle: String, databaseURL: URL) throws {
        let scopedAccess = SecurityScopedAccess(url: databaseURL)
        let store = try SQLiteDictionaryStore(databaseURL: databaseURL)
        self.scopedAccess = scopedAccess
        self.dictionaryID = dictionaryID
        self.dictionaryTitle = dictionaryTitle
        lookupService = DictionaryLookup(store: store)
    }

    func lookup(
        text: String,
        position: Int,
        requestID: UInt64
    ) async throws -> DictionaryLookupResult {
        try Task.checkCancellation()
        let signpostID = TsubameLogging.signposter.makeSignpostID()
        let interval = TsubameLogging.signposter.beginInterval("Lookup", id: signpostID)
        defer {
            TsubameLogging.signposter.endInterval("Lookup", interval)
        }

        TsubameLogging.lookup.debug(
            "request=\(requestID, privacy: .public) dictionary=\(self.dictionaryTitle, privacy: .public) lookup started bytes=\(text.utf8.count, privacy: .public) position=\(position, privacy: .public)"
        )
        let request = try PositionedLookupRequest(
            text: text,
            position: position,
            resultLimit: 100
        )
        let result = try lookupService.lookup(request)
        try Task.checkCancellation()
        TsubameLogging.lookup.notice(
            "request=\(requestID, privacy: .public) dictionary=\(self.dictionaryTitle, privacy: .public) lookup completed entries=\(result.entries.count, privacy: .public) range=\(result.sourceRange.start, privacy: .public)..<\(result.sourceRange.end, privacy: .public)"
        )
        return DictionaryLookupResult(
            entries: result.entries.map {
                DictionaryLookupEntry(
                    dictionaryID: dictionaryID,
                    dictionaryTitle: dictionaryTitle,
                    sourceRange: result.sourceRange,
                    entry: $0
                )
            }
        )
    }
}

actor DictionaryCollection: DictionaryLookingUp {
    private let dictionaries: [any DictionaryLookingUp]

    init(records: [InstalledDictionaryRecord]) throws {
        dictionaries = try records.map {
            try DictionaryEngine(
                dictionaryID: $0.id,
                dictionaryTitle: $0.manifest.title,
                databaseURL: $0.databaseURL
            )
        }
    }

    init(dictionaries: [any DictionaryLookingUp]) {
        self.dictionaries = dictionaries
    }

    func lookup(
        text: String,
        position: Int,
        requestID: UInt64
    ) async throws -> DictionaryLookupResult {
        TsubameLogging.lookup.debug(
            "request=\(requestID, privacy: .public) collection lookup started dictionaries=\(self.dictionaries.count, privacy: .public)"
        )
        let indexed = try await withThrowingTaskGroup(
            of: (Int, DictionaryLookupResult).self
        ) { group in
            for (index, dictionary) in dictionaries.enumerated() {
                group.addTask {
                    (
                        index,
                        try await dictionary.lookup(
                            text: text,
                            position: position,
                            requestID: requestID
                        )
                    )
                }
            }
            var results: [(Int, DictionaryLookupResult)] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
        let entries = indexed.flatMap(\.1.entries)
        TsubameLogging.lookup.notice(
            "request=\(requestID, privacy: .public) collection lookup completed dictionaries=\(self.dictionaries.count, privacy: .public) entries=\(entries.count, privacy: .public)"
        )
        return DictionaryLookupResult(entries: entries)
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
