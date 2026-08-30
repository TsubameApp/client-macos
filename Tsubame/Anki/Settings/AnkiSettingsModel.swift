import Foundation
import Observation
import OSLog

enum AnkiConnectionState: Sendable, Equatable {
    case notTested
    case connecting
    case connected(version: Int)
    case failed(String)
}

@MainActor
@Observable
final class AnkiSettingsModel {
    var enabled: Bool {
        didSet { persist() }
    }
    var endpoint: String {
        didSet {
            connectionState = .notTested
            persist()
        }
    }
    var deckName: String {
        didSet { persist() }
    }
    private(set) var modelName: String
    var tagsText: String {
        didSet { persist() }
    }
    private(set) var fieldTemplates: [String: String]
    private(set) var deckNames: [String] = []
    private(set) var modelNames: [String] = []
    private(set) var modelFieldNames: [String] = []
    private(set) var connectionState: AnkiConnectionState = .notTested
    private(set) var isLoadingModelFields = false

    static let supportedMarkers = [
        "{expression}",
        "{reading}",
        "{furigana}",
        "{selection-text}",
        "{definition}",
        "{definitions}",
        "{sentence}",
        "{cloze-sentence}",
        "{dictionary}",
        "{source-application}"
    ]

    @ObservationIgnored private let store: AnkiSettingsStore
    @ObservationIgnored private let clientProvider: (URL) -> any AnkiConnectServing
    @ObservationIgnored private var operationID: UInt64 = 0

    init(
        store: AnkiSettingsStore = .init(),
        clientProvider: @escaping (URL) -> any AnkiConnectServing = {
            AnkiConnectClient(endpoint: $0)
        }
    ) {
        self.store = store
        self.clientProvider = clientProvider
        let settings = store.load()
        enabled = settings.enabled
        endpoint = settings.endpoint
        deckName = settings.deckName
        modelName = settings.modelName
        tagsText = settings.tags.joined(separator: " ")
        fieldTemplates = settings.fieldTemplates
        modelFieldNames = settings.modelFieldNames
    }

    var connectionMessage: String {
        switch connectionState {
        case .notTested:
            "Anki connection has not been tested."
        case .connecting:
            "Connecting to Anki…"
        case .connected(let version):
            "Connected to AnkiConnect API v\(version)."
        case .failed(let message):
            message
        }
    }

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    var mappingIssues: [String] {
        let templates = fieldTemplates.values.joined(separator: " ")
        var issues: [String] = []
        if !templates.contains("{expression}") {
            issues.append("map an expression field")
        }
        if !templates.contains("{definition}") && !templates.contains("{definitions}") {
            issues.append("map a definition field")
        }
        if !templates.contains("{reading}") && !templates.contains("{furigana}") {
            issues.append("map a reading or furigana field")
        }
        return issues
    }

    func applySuggestedMappings() {
        for field in modelFieldNames {
            fieldTemplates[field] = Self.suggestedTemplate(for: field) ?? ""
        }
        persist()
    }

    func testConnection() async {
        operationID &+= 1
        let currentOperation = operationID
        connectionState = .connecting
        isLoadingModelFields = false

        do {
            let url = try AnkiConnectEndpoint.validate(endpoint)
            let client = clientProvider(url)
            let version = try await client.version()
            guard version >= AnkiConnectClient.apiVersion else {
                throw AnkiConnectError.incompatibleVersion(version)
            }
            async let loadedDecks = client.deckNames()
            async let loadedModels = client.modelNames()
            let (decks, models) = try await (loadedDecks, loadedModels)
            guard currentOperation == operationID else { return }

            deckNames = decks.sorted(by: localizedAscending)
            modelNames = models.sorted(by: localizedAscending)
            if !deckName.isEmpty, !deckNames.contains(deckName) {
                deckName = ""
            }
            if !modelName.isEmpty, !modelNames.contains(modelName) {
                modelName = ""
                modelFieldNames = []
                fieldTemplates = [:]
                persist()
            }
            connectionState = .connected(version: version)
            TsubameLogging.anki.notice(
                "Anki connected apiVersion=\(version, privacy: .public) decks=\(decks.count, privacy: .public) models=\(models.count, privacy: .public)"
            )

            if !modelName.isEmpty {
                try await loadModelFields(using: client, operationID: currentOperation)
            }
        } catch is CancellationError {
            return
        } catch {
            guard currentOperation == operationID else { return }
            deckNames = []
            modelNames = []
            modelFieldNames = []
            connectionState = .failed(error.localizedDescription)
            TsubameLogging.anki.error(
                "Anki connection failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func selectModel(_ selectedModel: String) async {
        guard selectedModel != modelName else { return }
        modelName = selectedModel
        modelFieldNames = []
        fieldTemplates = [:]
        persist()
        guard !selectedModel.isEmpty, isConnected else { return }

        operationID &+= 1
        let currentOperation = operationID
        do {
            let url = try AnkiConnectEndpoint.validate(endpoint)
            try await loadModelFields(
                using: clientProvider(url),
                operationID: currentOperation
            )
        } catch {
            guard currentOperation == operationID else { return }
            isLoadingModelFields = false
            connectionState = .failed(error.localizedDescription)
            TsubameLogging.anki.error(
                "Anki model fields failed model=\(selectedModel, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func setFieldTemplate(_ template: String, for field: String) {
        guard modelFieldNames.contains(field) else { return }
        fieldTemplates[field] = template
        persist()
    }

    private func loadModelFields(
        using client: any AnkiConnectServing,
        operationID currentOperation: UInt64
    ) async throws {
        let selectedModel = modelName
        guard !selectedModel.isEmpty else { return }
        isLoadingModelFields = true
        defer {
            if currentOperation == operationID {
                isLoadingModelFields = false
            }
        }

        let fields = try await client.modelFieldNames(modelName: selectedModel)
        guard currentOperation == operationID, modelName == selectedModel else { return }
        modelFieldNames = fields
        fieldTemplates = fieldTemplates.filter { fields.contains($0.key) }
        if fieldTemplates.values.allSatisfy(\.isEmpty) {
            for field in fields {
                if let suggested = Self.suggestedTemplate(for: field) {
                    fieldTemplates[field] = suggested
                }
            }
        }
        persist()
        TsubameLogging.anki.notice(
            "Anki model fields loaded model=\(selectedModel, privacy: .public) fields=\(fields.count, privacy: .public)"
        )
    }

    private func persist() {
        let tags = tagsText
            .split { $0.isWhitespace || $0 == "," }
            .map(String.init)
        store.save(
            AnkiSettings(
                enabled: enabled,
                endpoint: endpoint,
                deckName: deckName,
                modelName: modelName,
                tags: tags,
                fieldTemplates: fieldTemplates,
                modelFieldNames: modelFieldNames
            )
        )
    }

    private static func suggestedTemplate(for field: String) -> String? {
        let normalized = field.lowercased().filter {
            $0.isLetter || $0.isNumber
        }
        return switch normalized {
        case "expression", "word", "key", "front":
            "{expression}"
        case "reading", "expressionreading":
            "{reading}"
        case "wordreading", "expressionfurigana", "wordfurigana", "furigana":
            "{furigana}"
        case "back":
            "{reading}<br>{definitions}"
        case "definition", "maindefinition", "primarydefinition", "glossary",
             "wordmeaning", "wordmeaningrussian":
            "{definitions}"
        case "sentence":
            "{cloze-sentence}"
        case "selectiontext":
            "{selection-text}"
        default:
            nil
        }
    }
}

private func localizedAscending(_ lhs: String, _ rhs: String) -> Bool {
    lhs.localizedStandardCompare(rhs) == .orderedAscending
}
