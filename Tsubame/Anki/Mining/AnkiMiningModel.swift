import Foundation
import Observation
import OSLog
import TsubameCore

struct AnkiMiningKey: Hashable, Sendable {
    let requestID: UInt64
    let dictionaryID: UUID
    let entryID: Int64
}

enum AnkiMiningState: Sendable, Equatable {
    case idle
    case adding
    case added(noteID: Int64)
    case duplicate
    case failed(String)
}

@MainActor
@Observable
final class AnkiMiningModel {
    @ObservationIgnored private let settings: AnkiSettingsModel
    @ObservationIgnored private let service: any AnkiMiningServing
    private var states: [AnkiMiningKey: AnkiMiningState] = [:]

    init(
        settings: AnkiSettingsModel,
        service: any AnkiMiningServing = AnkiMiningService()
    ) {
        self.settings = settings
        self.service = service
    }

    var isEnabled: Bool {
        settings.enabled
    }

    func state(
        requestID: UInt64,
        dictionaryID: UUID,
        entryID: Int64
    ) -> AnkiMiningState {
        states[AnkiMiningKey(
            requestID: requestID,
            dictionaryID: dictionaryID,
            entryID: entryID
        )] ?? .idle
    }

    func beginRequest(_ requestID: UInt64) {
        states = states.filter { $0.key.requestID == requestID }
    }

    @discardableResult
    func mine(
        requestID: UInt64,
        dictionaryID: UUID,
        entry: DictionaryEntry,
        selectedText: String,
        contextText: String,
        matchedRange: UTF8TextRange,
        dictionaryTitle: String,
        sourceApplication: String
    ) -> Task<Void, Never>? {
        let key = AnkiMiningKey(
            requestID: requestID,
            dictionaryID: dictionaryID,
            entryID: entry.id
        )
        switch states[key] {
        case .adding, .added:
            return nil
        default:
            break
        }

        let configuration: AnkiMiningConfiguration
        do {
            configuration = try settings.miningConfiguration()
        } catch {
            states[key] = .failed(error.localizedDescription)
            return nil
        }
        let candidate = MiningCandidate(
            entry: entry,
            selectedText: selectedText,
            contextText: contextText,
            matchedRange: matchedRange,
            dictionaryTitle: dictionaryTitle,
            sourceApplication: sourceApplication
        )
        TsubameLogging.anki.notice(
            "request=\(requestID, privacy: .public) mining context selectedBytes=\(candidate.selectedText.utf8.count, privacy: .public) sentenceBytes=\(candidate.sentence.utf8.count, privacy: .public) match=\(candidate.sentenceMatchedRange.start, privacy: .public)..<\(candidate.sentenceMatchedRange.end, privacy: .public)"
        )
        states[key] = .adding
        TsubameLogging.anki.notice(
            "request=\(requestID, privacy: .public) Anki mining started entryID=\(entry.id, privacy: .public) deck=\(configuration.deckName, privacy: .public) model=\(configuration.modelName, privacy: .public)"
        )

        return Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.mine(
                    candidate,
                    configuration: configuration
                )
                switch result {
                case .added(let noteID):
                    states[key] = .added(noteID: noteID)
                    TsubameLogging.anki.notice(
                        "request=\(requestID, privacy: .public) Anki note added entryID=\(entry.id, privacy: .public) noteID=\(noteID, privacy: .public)"
                    )
                case .duplicate:
                    states[key] = .duplicate
                    TsubameLogging.anki.notice(
                        "request=\(requestID, privacy: .public) Anki duplicate rejected entryID=\(entry.id, privacy: .public)"
                    )
                }
            } catch is CancellationError {
                states[key] = .idle
            } catch {
                states[key] = .failed(error.localizedDescription)
                TsubameLogging.anki.error(
                    "request=\(requestID, privacy: .public) Anki mining failed entryID=\(entry.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
