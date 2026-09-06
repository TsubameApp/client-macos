import Foundation
import OSLog
import TsubameCore

struct SourcedDictionaryMetadata: Sendable {
    let title: String
    let metadata: DictionaryEntryMetadata
}

struct DictionaryContent: Sendable {
    let details: DictionaryEntryDetails
    let preparedDefinitions: [PreparedGlossaryDefinition]
    let imageReferences: [DictionaryImageReference]
    let sources: [SourcedDictionaryMetadata]
}

struct DictionaryArticle: Sendable, Identifiable {
    let variants: [DictionaryLookupEntry]
    var id: DictionaryLookupEntry.ID { variants[0].id }
}

actor DictionaryContentService {
    static let shared = DictionaryContentService()
    private struct EntryKey: Hashable { let bundle: URL; let id: Int64 }
    private struct MetadataKey: Hashable { let bundle: URL; let expression: String; let reading: String }
    private struct ContentKey: Hashable { let entry: EntryKey; let sources: [URL] }
    private var stores: [URL: SQLiteDictionaryStore] = [:]
    private var titles: [URL: String] = [:]
    private var details = DictionaryLRUCache<ContentKey, DictionaryContent>(countLimit: 64, costLimit: 16 * 1_024 * 1_024)
    private var payloads = DictionaryLRUCache<EntryKey, [Data]>(countLimit: 256, costLimit: 8 * 1_024 * 1_024)
    private var metadata = DictionaryLRUCache<MetadataKey, DictionaryEntryMetadata>(countLimit: 512, costLimit: 4 * 1_024 * 1_024)

    func load(_ entry: DictionaryLookupEntry) throws -> DictionaryContent? {
        guard let bundle = entry.bundleURL else { return nil }
        try Task.checkCancellation()
        let sourceURLs = entry.metadataBundleURLs.isEmpty ? [bundle] : entry.metadataBundleURLs
        let key = ContentKey(entry: .init(bundle: bundle, id: entry.entry.id), sources: sourceURLs)
        if let cached = details.value(for: key) { return cached }
        let interval = TsubameLogging.signposter.beginInterval("EntryDetailsLoad")
        defer { TsubameLogging.signposter.endInterval("EntryDetailsLoad", interval) }
        let result = try store(bundle).loadEntryDetails(entryID: entry.entry.id)
        cacheMetadata(result.metadata, bundle: bundle, entry: entry)
        var sources: [SourcedDictionaryMetadata] = []
        for url in sourceURLs {
            try Task.checkCancellation()
            let key = MetadataKey(bundle: url, expression: entry.entry.expression, reading: entry.entry.reading)
            let value: DictionaryEntryMetadata
            if let cached = metadata.value(for: key) { value = cached }
            else {
                do { value = try store(url).loadTermMetadata(expression: key.expression, reading: key.reading) }
                catch is CancellationError { throw CancellationError() }
                catch { continue }
                cacheMetadata(value, bundle: url, entry: entry)
            }
            guard !value.frequencies.isEmpty || !value.pitches.isEmpty else { continue }
            if titles[url] == nil {
                titles[url] = (try? JSONDecoder().decode(DictionaryBundleManifest.self,
                    from: Data(contentsOf: url.appending(path: "manifest.json"))).title) ?? url.lastPathComponent
            }
            sources.append(.init(title: titles[url]!, metadata: value))
        }
        try Task.checkCancellation()
        let preparedDefinitions = result.definitions.map {
            PreparedGlossaryDefinition(position: $0.position, glossary: PreparedGlossary(nodes: $0.nodes))
        }
        var imagePaths = Set<String>()
        let imageReferences = result.definitions
            .flatMap(\.nodes)
            .flatMap(\.images)
            .filter { imagePaths.insert($0.path.rawValue).inserted }
        let content = DictionaryContent(
            details: result,
            preparedDefinitions: preparedDefinitions,
            imageReferences: imageReferences,
            sources: sources
        )
        let bytes = try rawPayloads(entry).reduce(0) { $0 + $1.count }
        details.insert(content, for: key, cost: max(1, bytes * 4 + metadataCost(result.metadata)))
        return content
    }

    /// Exact ordered JSON equality, not sequence or plain-text equality. Preserve
    /// distinct meanings, tags, expressions and source ranges. All IDs survive.
    func articles(_ entries: [DictionaryLookupEntry]) throws -> [DictionaryArticle] {
        let interval = TsubameLogging.signposter.beginInterval("ArticleGrouping")
        defer { TsubameLogging.signposter.endInterval("ArticleGrouping", interval) }
        struct Bucket: Hashable {
            let dictionary: UUID
            let range: UTF8TextRange
            let expression: String
            let rules: String
        }
        func bucket(_ entry: DictionaryLookupEntry) -> Bucket {
            .init(dictionary: entry.dictionaryID, range: entry.sourceRange,
                  expression: entry.entry.expression, rules: entry.entry.rules)
        }
        let counts = Dictionary(grouping: entries, by: bucket).mapValues(\.count)
        var candidates: [Bucket: [(payloads: [Data], index: Int)]] = [:]
        var result: [DictionaryArticle] = []
        for entry in entries {
            try Task.checkCancellation()
            let key = bucket(entry)
            if counts[key, default: 0] > 1, let raw = try? rawPayloads(entry), !raw.isEmpty {
                if let match = candidates[key]?.first(where: { $0.payloads == raw }) {
                    result[match.index] = .init(variants: result[match.index].variants + [entry])
                    continue
                }
                candidates[key, default: []].append((raw, result.count))
            }
            result.append(.init(variants: [entry]))
        }
        try Task.checkCancellation()
        TsubameLogging.performance.debug("articles grouped input=\(entries.count, privacy: .public) output=\(result.count, privacy: .public)")
        return result
    }

    private func rawPayloads(_ entry: DictionaryLookupEntry) throws -> [Data] {
        guard let bundle = entry.bundleURL else { return entry.entry.definitions.map(\.contentJSON) }
        let key = EntryKey(bundle: bundle, id: entry.entry.id)
        if let value = payloads.value(for: key) { return value }
        let value = try store(bundle).loadDefinitionPayloads(entryID: entry.entry.id)
        payloads.insert(value, for: key, cost: max(1, value.reduce(0) { $0 + $1.count }))
        return value
    }

    private func metadataCost(_ value: DictionaryEntryMetadata) -> Int {
        max(1, value.frequencies.reduce(0) { $0 + $1.displayValue.utf8.count + 64 }
            + value.pitches.reduce(0) { $0 + $1.reading.utf8.count + $1.tags.joined().utf8.count + 256 }
            + (value.termTags + value.definitionTags).reduce(0) { $0 + $1.name.utf8.count + $1.notes.utf8.count + 64 })
    }

    private func cacheMetadata(_ value: DictionaryEntryMetadata, bundle: URL, entry: DictionaryLookupEntry) {
        metadata.insert(value, for: MetadataKey(bundle: bundle, expression: entry.entry.expression, reading: entry.entry.reading), cost: metadataCost(value))
    }

    func invalidate() {
        details.removeAll(); payloads.removeAll(); metadata.removeAll()
        titles.removeAll(); stores.removeAll()
    }

    private func store(_ bundle: URL) throws -> SQLiteDictionaryStore {
        if let store = stores[bundle] { return store }
        let store = try SQLiteDictionaryStore(databaseURL: bundle.appending(path: "dictionary.sqlite"))
        stores[bundle] = store
        return store
    }
}
