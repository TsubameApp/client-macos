import Foundation
import OSLog

enum AnkiMiningError: LocalizedError, Sendable, Equatable {
    case incompleteConfiguration(String? = nil)

    var errorDescription: String? {
        switch self {
        case .incompleteConfiguration(let details):
            if let details {
                "Anki mapping is incomplete: \(details)."
            } else {
                "Enable Anki and choose a deck, note type, and field mapping in Tsubame settings."
            }
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
    private let speechSynthesizer: any LocalSpeechSynthesizing

    init(
        renderer: AnkiFieldRenderer = .init(),
        speechSynthesizer: any LocalSpeechSynthesizing = AppleSpeechSynthesizer(),
        clientProvider: @escaping @Sendable (URL) -> any AnkiConnectServing = {
            AnkiConnectClient(endpoint: $0)
        }
    ) {
        self.renderer = renderer
        self.speechSynthesizer = speechSynthesizer
        self.clientProvider = clientProvider
    }

    func mine(
        _ candidate: MiningCandidate,
        configuration: AnkiMiningConfiguration
    ) async throws -> AnkiMiningResult {
        let rendered = try renderer.render(
            candidate: candidate,
            configuration: configuration
        )
        let fieldSummary = rendered.values
            .filter { !$0.value.isEmpty }
            .map { "\($0.key)=\($0.value.utf8.count)B" }
            .sorted()
            .joined(separator: ",")
        TsubameLogging.anki.notice(
            "Anki payload rendered nonEmptyFields=\(fieldSummary, privacy: .public)"
        )
        let noteWithoutAudio = AnkiNote(
            deckName: configuration.deckName,
            modelName: configuration.modelName,
            fields: rendered.values,
            tags: configuration.tags
        )
        let client = clientProvider(configuration.endpoint)
        guard try await client.canAddNote(noteWithoutAudio) else {
            return .duplicate
        }
        let audio: [AnkiNote.MediaAttachment]?
        if configuration.audioEnabled, !rendered.audioFields.isEmpty {
            let speechText = candidate.reading.isEmpty
                ? candidate.expression
                : candidate.reading
            let synthesized = try await speechSynthesizer.synthesize(
                text: speechText,
                voiceIdentifier: configuration.audioVoiceIdentifier,
                rate: configuration.audioRate
            )
            audio = [AnkiNote.MediaAttachment(
                filename: synthesized.filename,
                data: synthesized.data.base64EncodedString(),
                fields: rendered.audioFields
            )]
        } else {
            audio = nil
        }
        let note = AnkiNote(
            deckName: configuration.deckName,
            modelName: configuration.modelName,
            fields: rendered.values,
            tags: configuration.tags,
            audio: audio
        )
        return .added(noteID: try await client.addNote(note))
    }
}
