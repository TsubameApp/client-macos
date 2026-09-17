import Testing
@testable import Tsubame

struct HotKeyFeedbackTests {
    @Test
    func accessibilityClassificationDistinguishesMissingSelectionStates() {
        #expect(
            AccessibilityCaptureClassification.missingSelectionError(
                exposesSelectionAttributes: true,
                completedTraversal: true,
                encounteredTimeout: false
            ) == .noSelection
        )
        #expect(
            AccessibilityCaptureClassification.missingSelectionError(
                exposesSelectionAttributes: false,
                completedTraversal: true,
                encounteredTimeout: false
            ) == .unsupportedApplication
        )
        #expect(
            AccessibilityCaptureClassification.missingSelectionError(
                exposesSelectionAttributes: false,
                completedTraversal: true,
                encounteredTimeout: true
            ) == .accessibilityTimedOut
        )
        #expect(
            AccessibilityCaptureClassification.missingSelectionError(
                exposesSelectionAttributes: false,
                completedTraversal: false,
                encounteredTimeout: false
            ) == .invalidAccessibilityValue
        )
    }

    @Test
    func feedbackExplainsUnsupportedAccessibilityWithoutClipboardAdvice() {
        let feedback = HotKeyFeedbackPresentation.captureFailure(
            .unsupportedApplication
        )
        let text = "\(feedback.title) \(feedback.message)".lowercased()

        #expect(feedback.kind == .unsupportedApplication)
        #expect(text.contains("accessibility"))
        #expect(!text.contains("clipboard"))
        #expect(!text.contains("copy"))
        #expect(
            HotKeyFeedbackPresentation.captureFailure(.noSelection).kind
                == .noSelection
        )
    }

    @Test
    func feedbackReplacesPreviousMessageAndIgnoresStaleDismissal() {
        var state = HotKeyFeedbackState()
        let firstGeneration = state.present(
            .captureFailure(.noSelection),
            requestID: 1
        )
        let secondGeneration = state.present(
            .captureFailure(.accessibilityTimedOut),
            requestID: 2
        )

        #expect(state.item?.requestID == 2)
        #expect(state.item?.presentation.kind == .accessibilityTimedOut)
        let dismissedStaleFeedback = state.dismiss(generation: firstGeneration)
        #expect(!dismissedStaleFeedback)
        #expect(state.item?.requestID == 2)
        let dismissedCurrentFeedback = state.dismiss(generation: secondGeneration)
        #expect(dismissedCurrentFeedback)
        #expect(state.item == nil)
    }
}
