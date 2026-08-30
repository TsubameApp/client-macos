import Foundation
import TsubameCore

struct CaptureLookupOutcome: Sendable {
    let snapshot: CaptureSnapshot
    let result: DictionaryLookupResult
    let captureDuration: Duration
    let lookupDuration: Duration
}

struct CaptureLookupCoordinator: Sendable {
    let captureProvider: any CaptureProvider
    let dictionary: any DictionaryLookingUp

    func execute(requestID: UInt64) async throws -> CaptureLookupOutcome {
        let clock = ContinuousClock()

        let captureStart = clock.now
        let snapshot = try await captureProvider.capture(requestID: requestID)
        let captureDuration = captureStart.duration(to: clock.now)
        try Task.checkCancellation()

        let lookupStart = clock.now
        let result = try await dictionary.lookup(
            text: snapshot.text,
            position: snapshot.selectedRange.start,
            requestID: requestID
        )
        let lookupDuration = lookupStart.duration(to: clock.now)
        try Task.checkCancellation()

        return CaptureLookupOutcome(
            snapshot: snapshot,
            result: result,
            captureDuration: captureDuration,
            lookupDuration: lookupDuration
        )
    }
}
