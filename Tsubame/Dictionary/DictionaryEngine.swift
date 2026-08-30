import Foundation
import OSLog
import TsubameCore

protocol DictionaryLookingUp: Sendable {
    func lookup(
        text: String,
        position: Int,
        requestID: UInt64
    ) async throws -> DictionaryLookupResult

    func scan(
        text: String,
        range: UTF8TextRange,
        requestID: UInt64
    ) async throws -> DictionaryScanResult
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

struct DictionaryScanGroup: Sendable, Equatable, Identifiable {
    let sourceRange: UTF8TextRange
    let entries: [DictionaryLookupEntry]

    var id: UTF8TextRange { sourceRange }
}

struct DictionaryScanResult: Sendable, Equatable {
    let groups: [DictionaryScanGroup]

    var entries: [DictionaryLookupEntry] {
        groups.flatMap(\.entries)
    }
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

    func scan(
        text: String,
        range: UTF8TextRange,
        requestID: UInt64
    ) async throws -> DictionaryScanResult {
        try Task.checkCancellation()
        let signpostID = TsubameLogging.signposter.makeSignpostID()
        let interval = TsubameLogging.signposter.beginInterval("Scan", id: signpostID)
        defer {
            TsubameLogging.signposter.endInterval("Scan", interval)
        }

        TsubameLogging.lookup.debug(
            "request=\(requestID, privacy: .public) dictionary=\(self.dictionaryTitle, privacy: .public) scan started bytes=\(text.utf8.count, privacy: .public) range=\(range.start, privacy: .public)..<\(range.end, privacy: .public)"
        )
        let request = try ScanLookupRequest(
            text: text,
            range: range,
            resultGroupLimit: 100,
            entriesPerGroupLimit: 100
        )
        let results = try lookupService.scan(request)
        try Task.checkCancellation()
        let groups = results.map { result in
            DictionaryScanGroup(
                sourceRange: result.sourceRange,
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
        let entryCount = groups.lazy.map(\.entries.count).reduce(0, +)
        TsubameLogging.lookup.notice(
            "request=\(requestID, privacy: .public) dictionary=\(self.dictionaryTitle, privacy: .public) scan completed groups=\(groups.count, privacy: .public) entries=\(entryCount, privacy: .public)"
        )
        return DictionaryScanResult(groups: groups)
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

    func scan(
        text: String,
        range: UTF8TextRange,
        requestID: UInt64
    ) async throws -> DictionaryScanResult {
        TsubameLogging.lookup.debug(
            "request=\(requestID, privacy: .public) collection scan started dictionaries=\(self.dictionaries.count, privacy: .public) range=\(range.start, privacy: .public)..<\(range.end, privacy: .public)"
        )
        let indexed = try await withThrowingTaskGroup(
            of: (Int, DictionaryScanResult).self
        ) { group in
            for (index, dictionary) in dictionaries.enumerated() {
                group.addTask {
                    (
                        index,
                        try await dictionary.scan(
                            text: text,
                            range: range,
                            requestID: requestID
                        )
                    )
                }
            }
            var results: [(Int, DictionaryScanResult)] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }

        var entriesByRange: [UTF8TextRange: [DictionaryLookupEntry]] = [:]
        for (_, result) in indexed {
            for group in result.groups {
                entriesByRange[group.sourceRange, default: []]
                    .append(contentsOf: group.entries)
            }
        }
        let groups = entriesByRange
            .map { sourceRange, entries in
                DictionaryScanGroup(sourceRange: sourceRange, entries: entries)
            }
            .sorted {
                if $0.sourceRange.start != $1.sourceRange.start {
                    return $0.sourceRange.start < $1.sourceRange.start
                }
                return $0.sourceRange.end > $1.sourceRange.end
            }
        let entryCount = groups.lazy.map(\.entries.count).reduce(0, +)
        TsubameLogging.lookup.notice(
            "request=\(requestID, privacy: .public) collection scan completed dictionaries=\(self.dictionaries.count, privacy: .public) groups=\(groups.count, privacy: .public) entries=\(entryCount, privacy: .public)"
        )
        return DictionaryScanResult(groups: groups)
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
