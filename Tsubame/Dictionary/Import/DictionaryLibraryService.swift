import Foundation
import TsubameCore

actor DictionaryLibraryService {
    let layout: DictionaryLibraryLayout
    private let cleanupLibrary: @Sendable (
        DictionaryLibraryLayout
    ) -> DictionaryLibraryCleanupReport
    private let recoverLibrary: @Sendable (
        DictionaryLibraryLayout
    ) -> DictionaryReplacementRecoveryReport
    private let loadLibrary: @Sendable (
        DictionaryLibraryLayout
    ) throws -> [InstalledDictionaryRecord]
    private let discardBundle: @Sendable (URL) throws -> Void
    private let installBundle: @Sendable (
        DictionaryLibraryLayout,
        URL,
        DictionaryImportProgressHandler?
    ) throws -> InstalledDictionaryRecord
    private let replaceBundle: @Sendable (
        DictionaryLibraryLayout,
        UUID,
        URL,
        DictionaryImportProgressHandler?
    ) throws -> InstalledDictionaryRecord

    init(
        locations: TsubameStorageLocations = MacStorageLocations.platformDefault(),
        cleanupLibrary: @escaping @Sendable (
            DictionaryLibraryLayout
        ) -> DictionaryLibraryCleanupReport = {
            DictionaryLibraryMaintenance(layout: $0).cleanupAbandonedImports()
        },
        recoverLibrary: @escaping @Sendable (
            DictionaryLibraryLayout
        ) -> DictionaryReplacementRecoveryReport = {
            DictionaryLibraryMaintenance(layout: $0)
                .recoverAbandonedReplacements()
        },
        loadLibrary: @escaping @Sendable (
            DictionaryLibraryLayout
        ) throws -> [InstalledDictionaryRecord] = {
            try MacDictionaryLibrary(layout: $0).load()
        },
        discardBundle: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        },
        installBundle: @escaping @Sendable (
            DictionaryLibraryLayout,
            URL,
            DictionaryImportProgressHandler?
        ) throws -> InstalledDictionaryRecord = { layout, sourceURL, progress in
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
        },
        replaceBundle: @escaping @Sendable (
            DictionaryLibraryLayout,
            UUID,
            URL,
            DictionaryImportProgressHandler?
        ) throws -> InstalledDictionaryRecord = { layout, dictionaryID, sourceURL, progress in
            let result = try YomitanDictionaryInstaller(layout: layout).replace(
                dictionaryID: dictionaryID,
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
    ) {
        layout = DictionaryLibraryLayout(locations: locations)
        self.cleanupLibrary = cleanupLibrary
        self.recoverLibrary = recoverLibrary
        self.loadLibrary = loadLibrary
        self.discardBundle = discardBundle
        self.installBundle = installBundle
        self.replaceBundle = replaceBundle
    }

    func load() throws -> [InstalledDictionaryRecord] {
        try loadLibrary(layout)
    }

    func prepareAndLoad() throws -> DictionaryLibraryStartupResult {
        let cleanupReport = cleanupLibrary(layout)
        let recoveryReport = recoverLibrary(layout)
        return DictionaryLibraryStartupResult(
            dictionaries: try loadLibrary(layout),
            cleanupReport: cleanupReport,
            recoveryReport: recoveryReport
        )
    }

    func install(
        from sourceURL: URL,
        progress: DictionaryImportProgressHandler? = nil
    ) throws -> InstalledDictionaryRecord {
        try installBundle(layout, sourceURL, progress)
    }

    func replace(
        dictionaryID: UUID,
        from sourceURL: URL,
        progress: DictionaryImportProgressHandler? = nil
    ) throws -> InstalledDictionaryRecord {
        try replaceBundle(layout, dictionaryID, sourceURL, progress)
    }

    func remove(dictionaryID: UUID) throws {
        let fileManager = FileManager.default
        let bundleURL = layout.dictionaryBundleURL(for: dictionaryID).standardizedFileURL
        let libraryURL = layout.dictionariesRootURL.standardizedFileURL

        guard bundleURL.deletingLastPathComponent() == libraryURL,
              bundleURL.lastPathComponent == dictionaryID.uuidString.lowercased() else {
            throw DictionaryRemovalError.unsafeBundleLocation(bundleURL)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DictionaryRemovalError.dictionaryNotFound(dictionaryID)
        }

        let manifestURL = layout.dictionaryManifestURL(for: dictionaryID)
        let manifest: DictionaryBundleManifest
        do {
            manifest = try JSONDecoder().decode(
                DictionaryBundleManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw DictionaryRemovalError.invalidManifest(manifestURL)
        }
        guard manifest.dictionaryID == dictionaryID,
              manifest.manifestVersion == DictionaryBundleManifest.currentVersion else {
            throw DictionaryRemovalError.invalidManifest(manifestURL)
        }

        try discardBundle(bundleURL)
    }
}

struct DictionaryLibraryStartupResult: Sendable, Equatable {
    let dictionaries: [InstalledDictionaryRecord]
    let cleanupReport: DictionaryLibraryCleanupReport
    let recoveryReport: DictionaryReplacementRecoveryReport
}

enum DictionaryRemovalError: LocalizedError, Equatable {
    case dictionaryNotFound(UUID)
    case unsafeBundleLocation(URL)
    case invalidManifest(URL)

    var errorDescription: String? {
        switch self {
        case .dictionaryNotFound:
            "The installed dictionary could not be found."
        case .unsafeBundleLocation:
            "Tsubame refused to remove a dictionary outside its library."
        case .invalidManifest:
            "Tsubame refused to remove a dictionary with an invalid manifest."
        }
    }
}
