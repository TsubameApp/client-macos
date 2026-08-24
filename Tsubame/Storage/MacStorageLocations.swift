import Foundation
import TsubameCore

enum MacStorageLocations {
    static func platformDefault(
        fileManager: FileManager = .default
    ) -> TsubameStorageLocations {
        let home = fileManager.homeDirectoryForCurrentUser
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? home
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
        let caches = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? home
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Caches", directoryHint: .isDirectory)

        return make(
            applicationSupportDirectory: applicationSupport,
            cachesDirectory: caches,
            temporaryDirectory: fileManager.temporaryDirectory
        )
    }

    static func make(
        applicationSupportDirectory: URL,
        cachesDirectory: URL,
        temporaryDirectory: URL
    ) -> TsubameStorageLocations {
        TsubameStorageLocations(
            dataRoot: applicationSupportDirectory.appending(
                path: "Tsubame",
                directoryHint: .isDirectory
            ),
            cacheRoot: cachesDirectory.appending(
                path: "Tsubame",
                directoryHint: .isDirectory
            ),
            temporaryRoot: temporaryDirectory
        )
    }
}
