import Foundation
import TsubameCore

actor DictionaryLibraryService {
    let layout: DictionaryLibraryLayout
    private let discardBundle: @Sendable (URL) throws -> Void

    init(
        locations: TsubameStorageLocations = MacStorageLocations.platformDefault(),
        discardBundle: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    ) {
        layout = DictionaryLibraryLayout(locations: locations)
        self.discardBundle = discardBundle
    }

    func load() throws -> [InstalledDictionaryRecord] {
        try MacDictionaryLibrary(layout: layout).load()
    }

    func install(
        from sourceURL: URL,
        progress: DictionaryImportProgressHandler? = nil
    ) throws -> InstalledDictionaryRecord {
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
