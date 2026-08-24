import Foundation
import Testing
import TsubameCore
@testable import Tsubame

struct TsubameTests {
    @Test
    func convertsUTF16SelectionToUTF8Offsets() throws {
        let text = "A食😀かな"
        let range = try CaptureTextRange.fromUTF16Range(
            NSRange(location: 1, length: 3),
            in: text
        )

        #expect(range == CaptureTextRange(start: 1, end: 8))
        #expect(range.substring(in: text) == "食😀")
    }

    @Test
    func fullCaptureRangeUsesUTF8Bytes() {
        let text = "食べました"

        #expect(
            CaptureTextRange.fullRange(of: text)
                == CaptureTextRange(start: 0, end: 15)
        )
    }

    @Test
    func rejectsInvalidTextRange() {
        #expect(throws: CaptureError.invalidTextRange) {
            try CaptureSnapshot(
                text: "食",
                selectedRange: CaptureTextRange(start: 1, end: 2),
                anchorRectangle: nil,
                sourceApplication: .testValue,
                method: .accessibility
            )
        }
    }

    @Test
    func coordinatorPassesCapturedSelectionToDictionary() async throws {
        let snapshot = try CaptureSnapshot(
            text: "食べました",
            selectedRange: .fullRange(of: "食べました"),
            anchorRectangle: nil,
            sourceApplication: .testValue,
            method: .accessibility
        )
        let dictionary = RecordingDictionary()
        let coordinator = CaptureLookupCoordinator(
            captureProvider: StaticCaptureProvider(snapshot: snapshot),
            dictionary: dictionary
        )

        let outcome = try await coordinator.execute(requestID: 42)
        let request = await dictionary.lastRequest

        #expect(outcome.snapshot == snapshot)
        #expect(request?.text == "食べました")
        #expect(request?.position == 0)
        #expect(request?.requestID == 42)
    }

    @Test
    func coordinatorPropagatesTypedCaptureFailures() async {
        for expected in [
            CaptureError.permissionDenied,
            .unsupportedApplication,
            .noSelection
        ] {
            let coordinator = CaptureLookupCoordinator(
                captureProvider: FailingCaptureProvider(error: expected),
                dictionary: RecordingDictionary()
            )

            do {
                _ = try await coordinator.execute(requestID: 1)
                Issue.record("Expected capture to fail with \(expected)")
            } catch let actual as CaptureError {
                #expect(actual == expected)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test
    func coordinatorHonorsCancellation() async throws {
        let coordinator = CaptureLookupCoordinator(
            captureProvider: SlowCaptureProvider(),
            dictionary: RecordingDictionary()
        )
        let task = Task {
            try await coordinator.execute(requestID: 7)
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private struct StaticCaptureProvider: CaptureProvider {
    let snapshot: CaptureSnapshot

    func capture(requestID: UInt64) async throws -> CaptureSnapshot {
        snapshot
    }
}

private struct FailingCaptureProvider: CaptureProvider {
    let error: CaptureError

    func capture(requestID: UInt64) async throws -> CaptureSnapshot {
        throw error
    }
}

private struct SlowCaptureProvider: CaptureProvider {
    func capture(requestID: UInt64) async throws -> CaptureSnapshot {
        try await Task.sleep(for: .seconds(10))
        throw CaptureError.noSelection
    }
}

private actor RecordingDictionary: DictionaryLookingUp {
    struct Request: Sendable {
        let text: String
        let position: Int
        let requestID: UInt64
    }

    private(set) var lastRequest: Request?

    func lookup(
        text: String,
        position: Int,
        requestID: UInt64
    ) async throws -> LookupResult {
        lastRequest = Request(
            text: text,
            position: position,
            requestID: requestID
        )
        return LookupResult(
            sourceRange: UTF8TextRange(start: position, end: position),
            entries: []
        )
    }
}

private extension SourceApplication {
    static let testValue = Self(
        processIdentifier: 100,
        bundleIdentifier: "com.example.Source",
        localizedName: "Source"
    )
}
