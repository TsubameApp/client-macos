import Foundation
import Testing
import TsubameCore
@testable import Tsubame

struct TsubameTests {
    @Test
    func macStorageLocationsUseClientOwnedRoots() {
        let applicationSupport = URL(fileURLWithPath: "/test/Application Support")
        let caches = URL(fileURLWithPath: "/test/Caches")
        let temporary = URL(fileURLWithPath: "/test/Temporary")

        let locations = MacStorageLocations.make(
            applicationSupportDirectory: applicationSupport,
            cachesDirectory: caches,
            temporaryDirectory: temporary
        )

        #expect(locations.dataRoot.path == applicationSupport.appending(path: "Tsubame").path)
        #expect(locations.cacheRoot.path == caches.appending(path: "Tsubame").path)
        #expect(locations.temporaryRoot.path == temporary.path)
    }

    @Test
    func appPreferencesPersistDictionarySettings() throws {
        let suiteName = "TsubameTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstDictionaryID = UUID()
        let secondDictionaryID = UUID()
        let preferences = AppPreferences(defaults: defaults)

        preferences.onboardingCompleted = true
        preferences.developerModeEnabled = true
        preferences.enabledDictionaryIDs = [firstDictionaryID]
        preferences.dictionaryOrderIDs = [secondDictionaryID, firstDictionaryID]

        let reloaded = AppPreferences(defaults: defaults)
        #expect(reloaded.onboardingCompleted)
        #expect(reloaded.developerModeEnabled)
        #expect(reloaded.enabledDictionaryIDs == [firstDictionaryID])
        #expect(reloaded.dictionaryOrderIDs == [secondDictionaryID, firstDictionaryID])
    }

    @Test
    func dictionaryOrderReconcilesInstalledAndNewDictionaries() {
        let firstID = UUID()
        let secondID = UUID()
        let removedID = UUID()
        let thirdID = UUID()
        let newID = UUID()

        let reconciled = DictionaryOrder.reconcile(
            preferred: [secondID, removedID, secondID, firstID],
            installed: [firstID, secondID, thirdID, newID],
            appending: [newID]
        )

        #expect(reconciled == [secondID, firstID, thirdID, newID])
    }

    @Test
    func dictionaryOrderMovesOnlyWithinBounds() {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let order = [firstID, secondID, thirdID]

        #expect(DictionaryOrder.moving(order, id: secondID, offset: -1)
            == [secondID, firstID, thirdID])
        #expect(DictionaryOrder.moving(order, id: secondID, offset: 1)
            == [firstID, thirdID, secondID])
        #expect(DictionaryOrder.moving(order, id: firstID, offset: -1) == order)
        #expect(DictionaryOrder.moving(order, id: thirdID, offset: 1) == order)
    }

    @Test
    func macDictionaryLibraryDiscoversInstalledBundle() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appending(path: "TsubameTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let locations = TsubameStorageLocations(
            dataRoot: temporaryRoot.appending(path: "Data", directoryHint: .isDirectory),
            cacheRoot: temporaryRoot.appending(path: "Cache", directoryHint: .isDirectory),
            temporaryRoot: temporaryRoot.appending(path: "Work", directoryHint: .isDirectory)
        )
        let layout = DictionaryLibraryLayout(locations: locations)
        let dictionaryID = UUID()
        let bundleURL = layout.dictionaryBundleURL(for: dictionaryID)
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let manifest = DictionaryBundleManifest(
            dictionaryID: dictionaryID,
            title: "Test Dictionary",
            revision: "1",
            dictionarySchemaVersion: 1,
            termCount: 42,
            termMetadataCount: 0,
            kanjiCount: 0,
            kanjiMetadataCount: 0,
            tagCount: 0,
            definitionCount: 42,
            lookupKeyCount: 42,
            resourceCount: 0,
            totalResourceBytes: 0
        )
        try JSONEncoder().encode(manifest).write(
            to: layout.dictionaryManifestURL(for: dictionaryID)
        )
        #expect(fileManager.createFile(
            atPath: layout.dictionaryDatabaseURL(for: dictionaryID).path,
            contents: Data()
        ))

        let installed = try MacDictionaryLibrary(layout: layout).load()

        #expect(installed.count == 1)
        #expect(installed.first?.id == dictionaryID)
        #expect(installed.first?.manifest.title == "Test Dictionary")
        #expect(
            installed.first?.databaseURL.resolvingSymlinksInPath().path
                == layout.dictionaryDatabaseURL(for: dictionaryID).resolvingSymlinksInPath().path
        )
    }

    @Test
    func popupPresentationKeepsDeveloperMetricsEnabledWhenTimingsArrive() {
        let presentation = PopupPresentation(
            requestID: 1,
            selectedText: "食",
            contextText: "食",
            sourceApplication: .testValue,
            result: DictionaryLookupResult(entries: []),
            timings: nil,
            showsPerformanceMetrics: true
        )
        let timings = PipelineTimings(
            capture: .milliseconds(1),
            lookup: .milliseconds(2),
            present: .milliseconds(3),
            total: .milliseconds(6)
        )

        let updated = presentation.with(timings: timings)

        #expect(updated.timings == timings)
        #expect(updated.showsPerformanceMetrics)
    }

    @Test
    func convertsUTF16SelectionToUTF8Offsets() throws {
        let text = "A食😀かな"
        let range = try CaptureTextRange.fromUTF16Range(
            NSRange(location: 1, length: 3),
            in: text
        )

        #expect(range == CaptureTextRange(start: 1, end: 8))
        #expect(range.substring(in: text) == "食😀")
    }

    @Test
    func fullCaptureRangeUsesUTF8Bytes() {
        let text = "食べました"

        #expect(
            CaptureTextRange.fullRange(of: text)
                == CaptureTextRange(start: 0, end: 15)
        )
    }

    @Test
    func captureContextKeepsFullTextAndExactUnicodeSelection() {
        let context = CaptureTextContext.resolve(
            selectedText: "食べ",
            fullText: "前です。彼は食べました。次です。",
            selectedUTF16Range: NSRange(location: 6, length: 2)
        )

        #expect(context.text == "前です。彼は食べました。次です。")
        #expect(context.selectedRange.substring(in: context.text) == "食べ")
        #expect(context.source == .elementValue)
    }

    @Test
    func captureContextReportsSelectionOnlyFallback() {
        let context = CaptureTextContext.resolve(
            selectedText: "食べる",
            fullText: nil,
            selectedUTF16Range: nil,
            fullTextSource: .sentenceTextMarker
        )

        #expect(context.text == "食べる")
        #expect(context.source == .selectionOnly)
    }

    @Test
    func sentenceContextExtractsJapaneseSentenceAndRelativeMatch() throws {
        let context = try #require(SentenceContext.extract(
            from: "前です。彼は食べました。次です。",
            matchedRange: UTF8TextRange(start: 18, end: 24)
        ))

        #expect(context.text == "彼は食べました。")
        #expect(context.matchedRange == UTF8TextRange(start: 6, end: 12))
    }

    @Test
    func dictionaryCollectionKeepsDictionaryOrderAndIdentity() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let collection = DictionaryCollection(dictionaries: [
            StaticDictionary(id: firstID, title: "First"),
            StaticDictionary(id: secondID, title: "Second")
        ])

        let result = try await collection.lookup(
            text: "食べる",
            position: 0,
            requestID: 1
        )

        #expect(result.entries.map(\.dictionaryTitle) == ["First", "Second"])
        #expect(Set(result.entries.map(\.id)).count == 2)
    }

    @Test
    func dictionaryCollectionPassesExactScanRange() async throws {
        let dictionary = RecordingDictionary()
        let collection = DictionaryCollection(dictionaries: [dictionary])
        let range = UTF8TextRange(start: 3, end: 18)

        _ = try await collection.scan(
            text: "前食べました後",
            range: range,
            requestID: 43
        )
        let request = await dictionary.lastScanRequest

        #expect(request?.text == "前食べました後")
        #expect(request?.range == range)
        #expect(request?.requestID == 43)
    }

    @Test
    func dictionaryCollectionMergesScanGroupsInSourceAndDictionaryOrder() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let compoundRange = UTF8TextRange(start: 0, end: 9)
        let prefixRange = UTF8TextRange(start: 0, end: 3)
        let trailingRange = UTF8TextRange(start: 12, end: 18)
        let collection = DictionaryCollection(dictionaries: [
            StaticScanDictionary(
                groups: [
                    makeScanGroup(
                        dictionaryID: firstID,
                        dictionaryTitle: "First",
                        sourceRange: trailingRange,
                        entryID: 3,
                        expression: "読む"
                    ),
                    makeScanGroup(
                        dictionaryID: firstID,
                        dictionaryTitle: "First",
                        sourceRange: compoundRange,
                        entryID: 1,
                        expression: "東海岸"
                    ),
                ],
                delay: .milliseconds(20)
            ),
            StaticScanDictionary(groups: [
                makeScanGroup(
                    dictionaryID: secondID,
                    dictionaryTitle: "Second",
                    sourceRange: prefixRange,
                    entryID: 2,
                    expression: "東"
                ),
                makeScanGroup(
                    dictionaryID: secondID,
                    dictionaryTitle: "Second",
                    sourceRange: compoundRange,
                    entryID: 1,
                    expression: "東海岸"
                ),
            ])
        ])

        let result = try await collection.scan(
            text: "東海岸、読む",
            range: UTF8TextRange(start: 0, end: 18),
            requestID: 44
        )

        #expect(result.groups.map(\.sourceRange) == [
            compoundRange,
            prefixRange,
            trailingRange,
        ])
        #expect(result.groups[0].entries.map(\.dictionaryTitle) == ["First", "Second"])
        #expect(result.entries.map(\.entry.expression) == [
            "東海岸",
            "東海岸",
            "東",
            "読む",
        ])
    }

    @Test
    func rejectsInvalidTextRange() {
        #expect(throws: CaptureError.invalidTextRange) {
            try CaptureSnapshot(
                text: "食",
                selectedRange: CaptureTextRange(start: 1, end: 2),
                anchorRectangle: nil,
                sourceApplication: .testValue,
                method: .accessibility
            )
        }
    }

    @Test
    func coordinatorPassesCapturedSelectionToDictionary() async throws {
        let snapshot = try CaptureSnapshot(
            text: "食べました",
            selectedRange: .fullRange(of: "食べました"),
            anchorRectangle: nil,
            sourceApplication: .testValue,
            method: .accessibility
        )
        let dictionary = RecordingDictionary()
        let coordinator = CaptureLookupCoordinator(
            captureProvider: StaticCaptureProvider(snapshot: snapshot),
            dictionary: dictionary
        )

        let outcome = try await coordinator.execute(requestID: 42)
        let request = await dictionary.lastRequest

        #expect(outcome.snapshot == snapshot)
        #expect(request?.text == "食べました")
        #expect(request?.position == 0)
        #expect(request?.requestID == 42)
    }

    @Test
    func coordinatorPropagatesTypedCaptureFailures() async {
        for expected in [
            CaptureError.permissionDenied,
            .unsupportedApplication,
            .noSelection
        ] {
            let coordinator = CaptureLookupCoordinator(
                captureProvider: FailingCaptureProvider(error: expected),
                dictionary: RecordingDictionary()
            )

            do {
                _ = try await coordinator.execute(requestID: 1)
                Issue.record("Expected capture to fail with \(expected)")
            } catch let actual as CaptureError {
                #expect(actual == expected)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test
    func coordinatorHonorsCancellation() async throws {
        let coordinator = CaptureLookupCoordinator(
            captureProvider: SlowCaptureProvider(),
            dictionary: RecordingDictionary()
        )
        let task = Task {
            try await coordinator.execute(requestID: 7)
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private struct StaticCaptureProvider: CaptureProvider {
    let snapshot: CaptureSnapshot

    func capture(requestID: UInt64) async throws -> CaptureSnapshot {
        snapshot
    }
}

private struct FailingCaptureProvider: CaptureProvider {
    let error: CaptureError

    func capture(requestID: UInt64) async throws -> CaptureSnapshot {
        throw error
    }
}

private struct SlowCaptureProvider: CaptureProvider {
    func capture(requestID: UInt64) async throws -> CaptureSnapshot {
        try await Task.sleep(for: .seconds(10))
        throw CaptureError.noSelection
    }
}

private actor RecordingDictionary: DictionaryLookingUp {
    struct Request: Sendable {
        let text: String
        let position: Int
        let requestID: UInt64
    }

    struct ScanRequest: Sendable {
        let text: String
        let range: UTF8TextRange
        let requestID: UInt64
    }

    private(set) var lastRequest: Request?
    private(set) var lastScanRequest: ScanRequest?

    func lookup(
        text: String,
        position: Int,
        requestID: UInt64
    ) async throws -> DictionaryLookupResult {
        lastRequest = Request(
            text: text,
            position: position,
            requestID: requestID
        )
        return DictionaryLookupResult(entries: [])
    }

    func scan(
        text: String,
        range: UTF8TextRange,
        requestID: UInt64
    ) async throws -> DictionaryScanResult {
        lastScanRequest = ScanRequest(
            text: text,
            range: range,
            requestID: requestID
        )
        return DictionaryScanResult(groups: [])
    }
}

private struct StaticDictionary: DictionaryLookingUp {
    let id: UUID
    let title: String

    func lookup(
        text: String,
        position: Int,
        requestID: UInt64
    ) async throws -> DictionaryLookupResult {
        let entry = DictionaryEntry(
            id: 1,
            expression: "食べる",
            reading: "たべる",
            definitionTags: nil,
            rules: "v1",
            score: 1,
            sequence: 1,
            termTags: "",
            matches: [],
            definitions: []
        )
        return DictionaryLookupResult(entries: [
            DictionaryLookupEntry(
                dictionaryID: id,
                dictionaryTitle: title,
                sourceRange: UTF8TextRange(start: 0, end: 6),
                entry: entry
            )
        ])
    }

    func scan(
        text: String,
        range: UTF8TextRange,
        requestID: UInt64
    ) async throws -> DictionaryScanResult {
        let result = try await lookup(
            text: text,
            position: range.start,
            requestID: requestID
        )
        return DictionaryScanResult(groups: [
            DictionaryScanGroup(
                sourceRange: range,
                entries: result.entries.map { entry in
                    DictionaryLookupEntry(
                        dictionaryID: entry.dictionaryID,
                        dictionaryTitle: entry.dictionaryTitle,
                        sourceRange: range,
                        entry: entry.entry
                    )
                }
            ),
        ])
    }
}

private struct StaticScanDictionary: DictionaryLookingUp {
    let groups: [DictionaryScanGroup]
    var delay: Duration?

    init(groups: [DictionaryScanGroup], delay: Duration? = nil) {
        self.groups = groups
        self.delay = delay
    }

    func lookup(
        text: String,
        position: Int,
        requestID: UInt64
    ) async throws -> DictionaryLookupResult {
        DictionaryLookupResult(entries: [])
    }

    func scan(
        text: String,
        range: UTF8TextRange,
        requestID: UInt64
    ) async throws -> DictionaryScanResult {
        if let delay {
            try await Task.sleep(for: delay)
        }
        return DictionaryScanResult(groups: groups)
    }
}

private func makeScanGroup(
    dictionaryID: UUID,
    dictionaryTitle: String,
    sourceRange: UTF8TextRange,
    entryID: Int64,
    expression: String
) -> DictionaryScanGroup {
    let entry = DictionaryEntry(
        id: entryID,
        expression: expression,
        reading: "",
        definitionTags: nil,
        rules: "",
        score: 1,
        sequence: 1,
        termTags: "",
        matches: [],
        definitions: []
    )
    return DictionaryScanGroup(
        sourceRange: sourceRange,
        entries: [
            DictionaryLookupEntry(
                dictionaryID: dictionaryID,
                dictionaryTitle: dictionaryTitle,
                sourceRange: sourceRange,
                entry: entry
            ),
        ]
    )
}

private extension SourceApplication {
    static let testValue = Self(
        processIdentifier: 100,
        bundleIdentifier: "com.example.Source",
        localizedName: "Source"
    )
}
