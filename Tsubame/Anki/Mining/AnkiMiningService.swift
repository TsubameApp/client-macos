import Foundation

enum AnkiMiningError: LocalizedError, Sendable, Equatable {
    case incompleteConfiguration

    var errorDescription: String? {
        switch self {
        case .incompleteConfiguration:
            "Enable Anki and choose a deck, note type, and field mapping in Tsubame settings."
        }
    }
}

enum AnkiMiningResult: Sendable, Equatable {
    case added(noteID: Int64)
    case duplicate
}

protocol AnkiMiningServing: Sendable {
    func mine(
        _ candidate: MiningCandidate,
        configuration: AnkiMiningConfiguration
    ) async throws -> AnkiMiningResult
}

struct AnkiMiningService: AnkiMiningServing {
    private let renderer: AnkiFieldRenderer
    private let clientProvider: @Sendable (URL) -> any AnkiConnectServing

    init(
        renderer: AnkiFieldRenderer = .init(),
        clientProvider: @escaping @Sendable (URL) -> any AnkiConnectServing = {
            AnkiConnectClient(endpoint: $0)
        }
    ) {
        self.renderer = renderer
        self.clientProvider = clientProvider
    }

    func mine(
        _ candidate: MiningCandidate,
        configuration: AnkiMiningConfiguration
    ) async throws -> AnkiMiningResult {
        let fields = try renderer.render(
            candidate: candidate,
            configuration: configuration
        )
        let note = AnkiNote(
            deckName: configuration.deckName,
            modelName: configuration.modelName,
            fields: fields,
            tags: configuration.tags
        )
        let client = clientProvider(configuration.endpoint)
        guard try await client.canAddNote(note) else {
            return .duplicate
        }
        return .added(noteID: try await client.addNote(note))
    }
}
