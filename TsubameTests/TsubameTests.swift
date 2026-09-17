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
    func dictionaryLibraryServiceRemovesOnlyTheRequestedBundle() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appending(path: "TsubameTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let locations = testStorageLocations(root: temporaryRoot)
        let layout = DictionaryLibraryLayout(locations: locations)
        let removedID = UUID()
        let retainedID = UUID()
        try makeInstalledDictionaryBundle(
            layout: layout,
            dictionaryID: removedID,
            title: "Removed"
        )
        try makeInstalledDictionaryBundle(
            layout: layout,
            dictionaryID: retainedID,
            title: "Retained"
        )
        let service = DictionaryLibraryService(
            locations: locations,
            discardBundle: { try FileManager.default.removeItem(at: $0) }
        )

        try await service.remove(dictionaryID: removedID)
        let installed = try await service.load()

        #expect(!fileManager.fileExists(
            atPath: layout.dictionaryBundleURL(for: removedID).path
        ))
        #expect(installed.map(\.id) == [retainedID])
        #expect(fileManager.fileExists(
            atPath: layout.dictionaryBundleURL(for: retainedID).path
        ))
    }

    @Test
    func dictionaryLibraryServiceRefusesAnInvalidManifest() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appending(path: "TsubameTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let locations = testStorageLocations(root: temporaryRoot)
        let layout = DictionaryLibraryLayout(locations: locations)
        let dictionaryID = UUID()
        try makeInstalledDictionaryBundle(
            layout: layout,
            dictionaryID: dictionaryID,
            manifestDictionaryID: UUID(),
            title: "Invalid"
        )
        let service = DictionaryLibraryService(
            locations: locations,
            discardBundle: { _ in
                Issue.record("Invalid dictionary bundle must not be discarded")
            }
        )

        do {
            try await service.remove(dictionaryID: dictionaryID)
            Issue.record("Expected invalid manifest rejection")
        } catch let error as DictionaryRemovalError {
            #expect(error == .invalidManifest(
                layout.dictionaryManifestURL(for: dictionaryID)
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(fileManager.fileExists(
            atPath: layout.dictionaryBundleURL(for: dictionaryID).path
        ))
    }

    @Test
    func dictionaryLibraryStartupCleansBeforeLoading() async throws {
        let recorder = LibraryStartupRecorder()
        let removedURL = URL(fileURLWithPath: "/test/.staging/import")
        let expectedReport = DictionaryLibraryCleanupReport(
            removedStagingDirectories: [removedURL]
        )
        let service = DictionaryLibraryService(
            locations: testStorageLocations(root: URL(fileURLWithPath: "/test")),
            cleanupLibrary: { _ in
                recorder.append("cleanup")
                return expectedReport
            },
            loadLibrary: { _ in
                recorder.append("load")
                return []
            }
        )

        let result = try await service.prepareAndLoad()

        #expect(recorder.values == ["cleanup", "load"])
        #expect(result.dictionaries.isEmpty)
        #expect(result.cleanupReport == expectedReport)
    }

    @Test @MainActor
    func startupCleanupIssuesDoNotBlockDictionaryLibraryLoad() async throws {
        let suiteName = "TsubameTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let issue = DictionaryLibraryCleanupIssue(
            url: URL(fileURLWithPath: "/test/.staging/leftover"),
            message: "Permission denied"
        )
        let service = DictionaryLibraryService(
            locations: testStorageLocations(root: URL(fileURLWithPath: "/test")),
            cleanupLibrary: { _ in
                DictionaryLibraryCleanupReport(issues: [issue])
            },
            loadLibrary: { _ in [] }
        )
        let model = AppModel(
            preferences: AppPreferences(defaults: defaults),
            libraryService: service
        )

        model.loadInstalledDictionaries()

        #expect(model.isLoadingLibrary)
        #expect(model.isDictionaryLibraryBusy)
        for _ in 0..<300 where model.isLoadingLibrary {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!model.isLoadingLibrary)
        #expect(model.installedDictionaries.isEmpty)
        #expect(model.status == "Import a Yomitan dictionary to begin. Some abandoned import files could not be removed.")
    }

    @Test @MainActor
    func cancellingBatchImportKeepsCompletedDictionaryAndIgnoresLateProgress() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appending(path: "TsubameTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let firstSource = temporaryRoot.appending(path: "first", directoryHint: .isDirectory)
        let secondSource = temporaryRoot.appending(path: "second", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: firstSource, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondSource, withIntermediateDirectories: true)
        try Data(#"{"title":"First","format":3,"revision":"1"}"#.utf8).write(
            to: firstSource.appending(path: "index.json")
        )
        try Data(#"[["鳥","とり","","",0,["bird"],1,""]]"#.utf8).write(
            to: firstSource.appending(path: "term_bank_1.json")
        )

        let locations = testStorageLocations(root: temporaryRoot)
        let service = DictionaryLibraryService(
            locations: locations,
            installBundle: { layout, sourceURL, progress in
                if sourceURL == secondSource {
                    progress?(.phaseStarted(.sourcePreparation))
                    do {
                        while true {
                            try Task.checkCancellation()
                            Thread.sleep(forTimeInterval: 0.005)
                        }
                    } catch {
                        progress?(.completed(elapsedSeconds: 999))
                        throw error
                    }
                }

                let result = try YomitanDictionaryInstaller(layout: layout).install(
                    from: DictionaryImportSource(url: sourceURL),
                    progress: progress
                )
                return InstalledDictionaryRecord(
                    id: result.dictionaryID,
                    manifest: result.manifest,
                    bundleURL: result.bundleURL,
                    databaseURL: result.databaseURL
                )
            }
        )
        let suiteName = "TsubameTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            preferences: AppPreferences(defaults: defaults),
            libraryService: service
        )

        model.importDictionaries(from: [firstSource, secondSource])
        for _ in 0..<300 where model.importProgressText != secondSource.lastPathComponent {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.importProgressText == secondSource.lastPathComponent)
        #expect(model.isImportingDictionary)

        model.cancelDictionaryImport()
        model.cancelDictionaryImport()
        #expect(model.isCancellingDictionaryImport)

        for _ in 0..<300 where model.isImportingDictionary {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!model.isImportingDictionary)
        #expect(!model.isCancellingDictionaryImport)
        #expect(model.installedDictionaries.count == 1)
        #expect(model.installedDictionaries.first?.manifest.title == "First")
        #expect(model.enabledDictionaryIDs == Set(model.installedDictionaries.map(\.id)))
        #expect(model.importProgressText == "Import cancelled")
        #expect(model.importProgressDetail == "1 of 2 imported")
        #expect(model.status == "Import cancelled — 1 of 2 dictionaries imported.")
    }

    @Test @MainActor
    func replacingDictionaryPreservesIdentityEnabledStateAndPriority() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appending(path: "TsubameTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let originalSource = try makeYomitanSourceDirectory(
            root: temporaryRoot,
            name: "original",
            title: "Update Test",
            revision: "1",
            term: "鳥"
        )
        let replacementSource = try makeYomitanSourceDirectory(
            root: temporaryRoot,
            name: "replacement",
            title: "Update Test",
            revision: "2",
            term: "猫"
        )
        let suiteName = "TsubameTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            preferences: AppPreferences(defaults: defaults),
            libraryService: DictionaryLibraryService(
                locations: testStorageLocations(root: temporaryRoot)
            )
        )

        model.importDictionaries(from: [originalSource])
        for _ in 0..<300 where model.isImportingDictionary {
            try await Task.sleep(for: .milliseconds(10))
        }
        let originalRecord = try #require(model.installedDictionaries.first)
        let originalOrder = model.dictionaryOrderIDs
        #expect(model.enabledDictionaryIDs.contains(originalRecord.id))

        model.replaceDictionary(id: originalRecord.id, from: replacementSource)
        for _ in 0..<300 where model.isImportingDictionary {
            try await Task.sleep(for: .milliseconds(10))
        }

        let replacementRecord = try #require(model.installedDictionaries.first)
        #expect(replacementRecord.id == originalRecord.id)
        #expect(replacementRecord.manifest.revision == "2")
        #expect(model.dictionaryOrderIDs == originalOrder)
        #expect(model.enabledDictionaryIDs.contains(originalRecord.id))
        #expect(model.status == "Updated Update Test from revision 1 to 2.")
    }

    @Test
    func popupPresentationKeepsDeveloperMetricsEnabledWhenTimingsArrive() {
        let presentation = PopupPresentation(
            requestID: 1,
            selectedText: "食",
            contextText: "食",
            sourceApplication: .testValue,
            result: DictionaryScanResult(groups: []),
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
    func scanPresentationChoosesLongestNonOverlappingGroupsAndKeepsAlternatives() {
        let dictionaryID = UUID()
        let compoundRange = UTF8TextRange(start: 0, end: 9)
        let prefixRange = UTF8TextRange(start: 0, end: 3)
        let suffixRange = UTF8TextRange(start: 3, end: 9)
        let trailingRange = UTF8TextRange(start: 12, end: 18)
        let result = DictionaryScanResult(groups: [
            makeScanGroup(
                dictionaryID: dictionaryID,
                dictionaryTitle: "Test",
                sourceRange: suffixRange,
                entryID: 3,
                expression: "海岸"
            ),
            makeScanGroup(
                dictionaryID: dictionaryID,
                dictionaryTitle: "Test",
                sourceRange: trailingRange,
                entryID: 4,
                expression: "読む"
            ),
            makeScanGroup(
                dictionaryID: dictionaryID,
                dictionaryTitle: "Test",
                sourceRange: prefixRange,
                entryID: 2,
                expression: "東"
            ),
            makeScanGroup(
                dictionaryID: dictionaryID,
                dictionaryTitle: "Test",
                sourceRange: compoundRange,
                entryID: 1,
                expression: "東海岸"
            ),
        ])

        let presentation = DictionaryScanPresentation(result: result)

        #expect(presentation.sections.map(\.group.sourceRange) == [
            compoundRange,
            trailingRange,
        ])
        #expect(presentation.sections[0].alternatives.map(\.sourceRange) == [
            prefixRange,
            suffixRange,
        ])
        #expect(presentation.sections[1].alternatives.isEmpty)
        #expect(presentation.entryCount == 2)
    }

    @Test
    func scanPresentationKeepsASingleWordAsOneSection() {
        let range = UTF8TextRange(start: 0, end: 15)
        let result = DictionaryScanResult(groups: [
            makeScanGroup(
                dictionaryID: UUID(),
                dictionaryTitle: "Test",
                sourceRange: range,
                entryID: 1,
                expression: "食べる"
            ),
        ])

        let presentation = DictionaryScanPresentation(result: result)

        #expect(presentation.sections.count == 1)
        #expect(presentation.sections[0].group.sourceRange == range)
        #expect(presentation.sections[0].alternatives.isEmpty)
        #expect(presentation.entryCount == 1)
    }

    @Test @MainActor
    func scanDeckStartsAtFirstWordAndMovesWithinBounds() {
        let firstRange = UTF8TextRange(start: 0, end: 3)
        let secondRange = UTF8TextRange(start: 3, end: 9)
        let presentation = DictionaryScanPresentation(result: DictionaryScanResult(groups: [
            makeScanGroup(
                dictionaryID: UUID(),
                dictionaryTitle: "Test",
                sourceRange: firstRange,
                entryID: 1,
                expression: "東"
            ),
            makeScanGroup(
                dictionaryID: UUID(),
                dictionaryTitle: "Test",
                sourceRange: secondRange,
                entryID: 2,
                expression: "海岸"
            ),
        ]))
        let deck = DictionaryScanDeckModel()

        deck.begin(requestID: 1, scan: presentation)
        #expect(deck.selectedSectionID == firstRange)

        deck.move(by: 1, in: presentation)
        #expect(deck.selectedSectionID == secondRange)

        deck.move(by: 1, in: presentation)
        #expect(deck.selectedSectionID == secondRange)

        deck.move(by: -1, in: presentation)
        #expect(deck.selectedSectionID == firstRange)
    }

    @Test @MainActor
    func scanDeckPreservesSelectionForUpdatesAndResetsForNewRequests() {
        let firstRange = UTF8TextRange(start: 0, end: 3)
        let secondRange = UTF8TextRange(start: 3, end: 9)
        let presentation = DictionaryScanPresentation(result: DictionaryScanResult(groups: [
            makeScanGroup(
                dictionaryID: UUID(),
                dictionaryTitle: "Test",
                sourceRange: firstRange,
                entryID: 1,
                expression: "東"
            ),
            makeScanGroup(
                dictionaryID: UUID(),
                dictionaryTitle: "Test",
                sourceRange: secondRange,
                entryID: 2,
                expression: "海岸"
            ),
        ]))
        let deck = DictionaryScanDeckModel()

        deck.begin(requestID: 1, scan: presentation)
        deck.select(secondRange, in: presentation)
        deck.begin(requestID: 1, scan: presentation)
        #expect(deck.selectedSectionID == secondRange)

        deck.begin(requestID: 2, scan: presentation)
        #expect(deck.selectedSectionID == firstRange)
    }

    @Test
    func dictionaryEntryIdentityIncludesItsSourceRange() {
        let dictionaryID = UUID()
        let first = makeScanGroup(
            dictionaryID: dictionaryID,
            dictionaryTitle: "Test",
            sourceRange: UTF8TextRange(start: 0, end: 3),
            entryID: 1,
            expression: "日"
        ).entries[0]
        let second = makeScanGroup(
            dictionaryID: dictionaryID,
            dictionaryTitle: "Test",
            sourceRange: UTF8TextRange(start: 6, end: 9),
            entryID: 1,
            expression: "日"
        ).entries[0]

        #expect(first.id != second.id)
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
    func coordinatorScansTheExactCapturedSelection() async throws {
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
        let request = await dictionary.lastScanRequest

        #expect(outcome.snapshot == snapshot)
        #expect(request?.text == "食べました")
        #expect(request?.range == UTF8TextRange(start: 0, end: 15))
        #expect(request?.requestID == 42)
        #expect(outcome.result.groups.isEmpty)
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

private func testStorageLocations(root: URL) -> TsubameStorageLocations {
    TsubameStorageLocations(
        dataRoot: root.appending(path: "Data", directoryHint: .isDirectory),
        cacheRoot: root.appending(path: "Cache", directoryHint: .isDirectory),
        temporaryRoot: root.appending(path: "Work", directoryHint: .isDirectory)
    )
}

private func makeInstalledDictionaryBundle(
    layout: DictionaryLibraryLayout,
    dictionaryID: UUID,
    manifestDictionaryID: UUID? = nil,
    title: String
) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        at: layout.dictionaryBundleURL(for: dictionaryID),
        withIntermediateDirectories: true
    )
    let manifest = DictionaryBundleManifest(
        dictionaryID: manifestDictionaryID ?? dictionaryID,
        title: title,
        revision: "1",
        dictionarySchemaVersion: 1,
        termCount: 1,
        termMetadataCount: 0,
        kanjiCount: 0,
        kanjiMetadataCount: 0,
        tagCount: 0,
        definitionCount: 1,
        lookupKeyCount: 1,
        resourceCount: 0,
        totalResourceBytes: 0
    )
    try JSONEncoder().encode(manifest).write(
        to: layout.dictionaryManifestURL(for: dictionaryID)
    )
    guard fileManager.createFile(
        atPath: layout.dictionaryDatabaseURL(for: dictionaryID).path,
        contents: Data()
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func makeYomitanSourceDirectory(
    root: URL,
    name: String,
    title: String,
    revision: String,
    term: String
) throws -> URL {
    let source = root.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data(
        "{\"title\":\"\(title)\",\"format\":3,\"revision\":\"\(revision)\"}".utf8
    ).write(to: source.appending(path: "index.json"))
    try Data(
        "[[\"\(term)\",\"\",\"\",\"\",0,[\"definition\"],1,\"\"]]".utf8
    ).write(to: source.appending(path: "term_bank_1.json"))
    return source
}

private extension SourceApplication {
    static let testValue = Self(
        processIdentifier: 100,
        bundleIdentifier: "com.example.Source",
        localizedName: "Source"
    )
}

private final class LibraryStartupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock {
            storage.append(value)
        }
    }
}
