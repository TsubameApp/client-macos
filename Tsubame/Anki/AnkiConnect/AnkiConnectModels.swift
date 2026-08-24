import Foundation

protocol AnkiConnectServing: Sendable {
    func version() async throws -> Int
    func deckNames() async throws -> [String]
    func modelNames() async throws -> [String]
    func modelFieldNames(modelName: String) async throws -> [String]
}

enum AnkiConnectError: LocalizedError, Sendable, Equatable {
    case invalidEndpoint
    case nonLoopbackEndpoint
    case invalidResponse
    case httpStatus(Int)
    case server(String)
    case incompatibleVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Enter a valid AnkiConnect URL."
        case .nonLoopbackEndpoint:
            "For now, AnkiConnect must run on this Mac."
        case .invalidResponse:
            "AnkiConnect returned an invalid response."
        case .httpStatus(let status):
            "AnkiConnect returned HTTP status \(status)."
        case .server(let message):
            "AnkiConnect error: \(message)"
        case .incompatibleVersion(let version):
            "AnkiConnect API version \(version) is too old. Version 5 or newer is required."
        }
    }
}

enum AnkiConnectEndpoint {
    static let defaultValue = "http://127.0.0.1:8765"

    static func validate(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url
        else {
            throw AnkiConnectError.invalidEndpoint
        }
        guard ["127.0.0.1", "localhost", "::1"].contains(host) else {
            throw AnkiConnectError.nonLoopbackEndpoint
        }
        return url
    }
}
