import Foundation
import Testing
@testable import Tsubame

struct AnkiConnectTests {
    @Test
    func validatesOnlyLoopbackEndpoints() throws {
        #expect(try AnkiConnectEndpoint.validate("http://127.0.0.1:8765").port == 8765)
        #expect(try AnkiConnectEndpoint.validate("http://localhost:8765").host == "localhost")
        #expect(throws: AnkiConnectError.nonLoopbackEndpoint) {
            try AnkiConnectEndpoint.validate("https://example.com")
        }
        #expect(throws: AnkiConnectError.invalidEndpoint) {
            try AnkiConnectEndpoint.validate("not a URL")
        }
    }

    @Test
    func decodesAnkiConnectResultsAndEncodesModelName() async throws {
        let transport = RecordingAnkiHTTPTransport(
            results: [
                "version": "5",
                "deckNames": "[\"Mining\",\"Default\"]",
                "modelNames": "[\"Lapis\"]",
                "modelFieldNames": "[\"Expression\",\"Sentence\"]"
            ]
        )
        let endpoint = try AnkiConnectEndpoint.validate(AnkiConnectEndpoint.defaultValue)
        let client = AnkiConnectClient(endpoint: endpoint, transport: transport)

        #expect(try await client.version() == 5)
        #expect(try await client.deckNames() == ["Mining", "Default"])
        #expect(try await client.modelNames() == ["Lapis"])
        #expect(
            try await client.modelFieldNames(modelName: "Lapis")
                == ["Expression", "Sentence"]
        )

        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.version == 5 })
        #expect(requests.last?.action == "modelFieldNames")
        #expect(requests.last?.modelName == "Lapis")
    }

    @Test
    func surfacesAnkiConnectServerErrors() async throws {
        let transport = RecordingAnkiHTTPTransport(
            results: [:],
            error: "collection is not available"
        )
        let endpoint = try AnkiConnectEndpoint.validate(AnkiConnectEndpoint.defaultValue)
        let client = AnkiConnectClient(endpoint: endpoint, transport: transport)

        await #expect(throws: AnkiConnectError.server("collection is not available")) {
            try await client.deckNames()
        }
    }
}

private actor RecordingAnkiHTTPTransport: AnkiHTTPTransport {
    struct RecordedRequest: Sendable {
        let action: String
        let version: Int
        let modelName: String?
    }

    private(set) var requests: [RecordedRequest] = []
    private let results: [String: String]
    private let error: String?

    init(results: [String: String], error: String? = nil) {
        self.results = results
        self.error = error
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try #require(request.httpBody)
        let json = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let action = try #require(json["action"] as? String)
        let version = try #require(json["version"] as? Int)
        let params = json["params"] as? [String: Any]
        requests.append(
            RecordedRequest(
                action: action,
                version: version,
                modelName: params?["modelName"] as? String
            )
        )

        let result = results[action] ?? "null"
        let errorJSON: String
        if let error {
            let data = try JSONEncoder().encode(error)
            errorJSON = String(decoding: data, as: UTF8.self)
        } else {
            errorJSON = "null"
        }
        let data = Data("{\"result\":\(result),\"error\":\(errorJSON)}".utf8)
        let response = try #require(
            HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (data, response)
    }
}
