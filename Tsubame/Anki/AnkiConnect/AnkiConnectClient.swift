import Foundation

protocol AnkiHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionAnkiHTTPTransport: AnkiHTTPTransport {
    private let session: URLSession

    init(timeout: TimeInterval = 2) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnkiConnectError.invalidResponse
        }
        return (data, httpResponse)
    }
}

struct AnkiConnectClient: AnkiConnectServing {
    static let apiVersion = 5

    let endpoint: URL
    private let transport: any AnkiHTTPTransport

    init(
        endpoint: URL,
        transport: any AnkiHTTPTransport = URLSessionAnkiHTTPTransport()
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func version() async throws -> Int {
        try await invoke("version", result: Int.self)
    }

    func deckNames() async throws -> [String] {
        try await invoke("deckNames", result: [String].self)
    }

    func modelNames() async throws -> [String] {
        try await invoke("modelNames", result: [String].self)
    }

    func modelFieldNames(modelName: String) async throws -> [String] {
        try await invoke(
            "modelFieldNames",
            params: ModelFieldNamesParams(modelName: modelName),
            result: [String].self
        )
    }

    func canAddNote(_ note: AnkiNote) async throws -> Bool {
        let results = try await invoke(
            "canAddNotes",
            params: NotesParams(notes: [note]),
            result: [Bool].self
        )
        guard let result = results.first else {
            throw AnkiConnectError.invalidResponse
        }
        return result
    }

    func addNote(_ note: AnkiNote) async throws -> Int64 {
        try await invoke(
            "addNote",
            params: NoteParams(note: note),
            result: Int64.self
        )
    }

    private func invoke<Result: Decodable>(
        _ action: String,
        result: Result.Type
    ) async throws -> Result {
        try await invoke(
            action,
            params: EmptyParams(),
            result: result
        )
    }

    private func invoke<Params: Encodable, Result: Decodable>(
        _ action: String,
        params: Params,
        result: Result.Type
    ) async throws -> Result {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RequestEnvelope(
                action: action,
                version: Self.apiVersion,
                params: params
            )
        )

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw AnkiConnectError.httpStatus(response.statusCode)
        }

        let envelope: ResponseEnvelope<Result>
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope<Result>.self, from: data)
        } catch {
            throw AnkiConnectError.invalidResponse
        }
        if let error = envelope.error {
            throw AnkiConnectError.server(error)
        }
        guard let result = envelope.result else {
            throw AnkiConnectError.invalidResponse
        }
        return result
    }
}

private struct RequestEnvelope<Params: Encodable>: Encodable {
    let action: String
    let version: Int
    let params: Params
}

private struct ResponseEnvelope<Result: Decodable>: Decodable {
    let result: Result?
    let error: String?
}

private struct EmptyParams: Encodable {}

private struct ModelFieldNamesParams: Encodable {
    let modelName: String
}

private struct NotesParams: Encodable {
    let notes: [AnkiNote]
}

private struct NoteParams: Encodable {
    let note: AnkiNote
}
