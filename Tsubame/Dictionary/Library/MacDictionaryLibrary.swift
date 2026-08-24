import Foundation
import TsubameCore

struct InstalledDictionaryRecord: Identifiable, Sendable, Equatable {
    let id: UUID
    let manifest: DictionaryBundleManifest
    let bundleURL: URL
    let databaseURL: URL
}

struct MacDictionaryLibrary: Sendable {
    let layout: DictionaryLibraryLayout

    func load(fileManager: FileManager = .default) throws -> [InstalledDictionaryRecord] {
        let root = layout.dictionariesRootURL
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        let bundleURLs = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var dictionaries: [InstalledDictionaryRecord] = []
        for bundleURL in bundleURLs {
            let values = try bundleURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true,
                  let dictionaryID = UUID(uuidString: bundleURL.lastPathComponent)
            else {
                continue
            }

            let manifestURL = bundleURL.appending(path: "manifest.json")
            let databaseURL = bundleURL.appending(path: "dictionary.sqlite")
            guard fileManager.fileExists(atPath: manifestURL.path),
                  fileManager.fileExists(atPath: databaseURL.path)
            else {
                throw MacDictionaryLibraryError.incompleteBundle(bundleURL)
            }

            let manifest: DictionaryBundleManifest
            do {
                manifest = try JSONDecoder().decode(
                    DictionaryBundleManifest.self,
                    from: Data(contentsOf: manifestURL)
                )
            } catch {
                throw MacDictionaryLibraryError.invalidManifest(
                    manifestURL,
                    reason: error.localizedDescription
                )
            }
            guard manifest.manifestVersion == DictionaryBundleManifest.currentVersion,
                  manifest.dictionaryID == dictionaryID
            else {
                throw MacDictionaryLibraryError.invalidManifest(
                    manifestURL,
                    reason: "Manifest identity or version does not match its bundle."
                )
            }

            dictionaries.append(
                InstalledDictionaryRecord(
                    id: dictionaryID,
                    manifest: manifest,
                    bundleURL: bundleURL,
                    databaseURL: databaseURL
                )
            )
        }
        return dictionaries.sorted {
            $0.manifest.title.localizedStandardCompare($1.manifest.title) == .orderedAscending
        }
    }
}

enum MacDictionaryLibraryError: LocalizedError {
    case incompleteBundle(URL)
    case invalidManifest(URL, reason: String)

    var errorDescription: String? {
        switch self {
        case .incompleteBundle(let url):
            "Dictionary bundle is incomplete: \(url.path)"
        case .invalidManifest(let url, let reason):
            "Dictionary manifest is invalid at \(url.path): \(reason)"
        }
    }
}
