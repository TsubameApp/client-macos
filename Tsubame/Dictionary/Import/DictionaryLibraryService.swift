import Foundation
import TsubameCore

actor DictionaryLibraryService {
    let layout: DictionaryLibraryLayout

    init(locations: TsubameStorageLocations = MacStorageLocations.platformDefault()) {
        layout = DictionaryLibraryLayout(locations: locations)
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
}
