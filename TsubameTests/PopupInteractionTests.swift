import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import Tsubame

struct PopupInteractionTests {
    @Test
    func mapsOnlySupportedUnmodifiedNavigationKeys() {
        #expect(command(kVK_LeftArrow) == .previousWord)
        #expect(command(kVK_RightArrow) == .nextWord)
        #expect(command(kVK_UpArrow) == .scrollUp)
        #expect(command(kVK_DownArrow) == .scrollDown)
        #expect(command(kVK_PageUp) == .pageUp)
        #expect(command(kVK_PageDown) == .pageDown)
        #expect(command(kVK_Escape) == .dismiss)

        #expect(command(kVK_ANSI_A) == nil)
        #expect(command(kVK_LeftArrow, flags: .maskCommand) == nil)
        #expect(command(kVK_Escape, flags: .maskShift) == nil)
    }

    @Test
    func mapsPinOnlyForExactCommandShiftP() {
        let pinFlags: CGEventFlags = [.maskCommand, .maskShift]

        #expect(command(kVK_ANSI_P, flags: pinFlags) == .togglePin)
        #expect(command(kVK_ANSI_P, flags: .maskCommand) == nil)
        #expect(command(
            kVK_ANSI_P,
            flags: pinFlags.union(.maskAlternate)
        ) == nil)
    }

    @Test @MainActor
    func pinPersistsOnlyForTheVisiblePopupSession() {
        let state = PopupInteractionState()

        #expect(!state.isVisible)
        #expect(!state.isPinned)
        #expect(!state.dismissesForOutsideClick)

        state.beginPresentation()
        #expect(state.isVisible)
        #expect(state.dismissesForOutsideClick)

        state.togglePin()
        #expect(state.isPinned)
        #expect(!state.dismissesForOutsideClick)

        state.beginPresentation()
        #expect(state.isPinned)

        state.hide()
        #expect(!state.isVisible)
        #expect(!state.isPinned)

        state.beginPresentation()
        #expect(!state.isPinned)
        #expect(state.dismissesForOutsideClick)
    }

    @Test @MainActor
    func hiddenPopupCannotBePinned() {
        let state = PopupInteractionState()

        state.togglePin()

        #expect(!state.isPinned)
    }

    @Test @MainActor
    func deckPublishesOrderedScrollRequests() {
        let deck = DictionaryScanDeckModel()

        deck.scroll(.lineDown)
        let first = deck.scrollRequest
        deck.scroll(.pageDown)
        let second = deck.scrollRequest
        deck.scroll(.top)
        let third = deck.scrollRequest

        #expect(first.command == .lineDown)
        #expect(second.command == .pageDown)
        #expect(third.command == .top)
        #expect(first.sequence < second.sequence)
        #expect(second.sequence < third.sequence)
    }

    @Test
    func pronunciationPreviewWaitsForAmbiguousReadingSelection() {
        #expect(PopupPronunciation.shouldShowPreview(
            variantCount: 1,
            selectedVariant: nil
        ))
        #expect(!PopupPronunciation.shouldShowPreview(
            variantCount: 2,
            selectedVariant: nil
        ))
        #expect(PopupPronunciation.shouldShowPreview(
            variantCount: 2,
            selectedVariant: 42
        ))
        #expect(PopupPronunciation.text(expression: "食べる", reading: "たべる") == "たべる")
        #expect(PopupPronunciation.text(expression: "かな", reading: "") == "かな")
    }

    @Test @MainActor
    func pronunciationPreviewUsesTheSelectedGlobalVoiceAndRate() async throws {
        let suiteName = "PopupInteractionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let synthesizer = RecordingPopupSpeechSynthesizer()
        let model = SpeechSettingsModel(
            preferences: AppPreferences(defaults: defaults),
            synthesizer: synthesizer
        )
        model.voiceIdentifier = "voice.jp"
        model.rate = 0.9

        model.togglePlayback(text: "たべる", key: "selected-reading")
        for _ in 0..<100 where synthesizer.calls.isEmpty {
            await Task.yield()
        }

        #expect(synthesizer.calls == [SpeechCall(
            text: "たべる",
            voiceIdentifier: "voice.jp",
            rate: 0.9
        )])
        model.stopPlayback()
    }

    private func command(
        _ keyCode: Int,
        flags: CGEventFlags = []
    ) -> PopupKeyboardCommand? {
        PopupKeyboardCommandMapper.command(
            keyCode: CGKeyCode(keyCode),
            flags: flags
        )
    }
}

private struct SpeechCall: Equatable {
    let text: String
    let voiceIdentifier: String?
    let rate: Double
}

@MainActor
private final class RecordingPopupSpeechSynthesizer: LocalSpeechSynthesizing {
    private(set) var calls: [SpeechCall] = []

    func synthesize(
        text: String,
        voiceIdentifier: String?,
        rate: Double
    ) async throws -> SynthesizedAudio {
        calls.append(SpeechCall(
            text: text,
            voiceIdentifier: voiceIdentifier,
            rate: rate
        ))
        return SynthesizedAudio(
            data: Data([0]),
            filename: "preview.m4a",
            mimeType: "audio/mp4"
        )
    }
}
