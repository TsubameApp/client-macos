import AppKit
import Foundation
import Observation

struct SpeechSettings: Sendable, Equatable {
    let enabled: Bool
    let voiceIdentifier: String?
    let rate: Double
}

enum AudioPreviewState: Sendable, Equatable {
    case idle
    case generating
    case playing
    case failed(String)
}

@MainActor
@Observable
final class SpeechSettingsModel: NSObject, NSSoundDelegate {
    private static let settingsPreviewKey = "settings-preview"

    var enabled: Bool {
        didSet {
            preferences.speechEnabled = enabled
            if !enabled { stopPlayback() }
        }
    }
    var voiceIdentifier: String? {
        didSet {
            preferences.speechVoiceIdentifier = voiceIdentifier
            stopPlayback()
        }
    }
    var rate: Double {
        didSet {
            preferences.speechRate = rate
            stopPlayback()
        }
    }
    let japaneseVoices: [LocalSpeechVoice]
    private(set) var activePlaybackKey: String?
    private(set) var activePlaybackState: AudioPreviewState = .idle

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let synthesizer: any LocalSpeechSynthesizing
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var playbackSound: NSSound?
    @ObservationIgnored private var audioCache: [SpeechCacheKey: Data] = [:]
    @ObservationIgnored private var cacheOrder: [SpeechCacheKey] = []

    init(
        preferences: AppPreferences = .init(),
        synthesizer: any LocalSpeechSynthesizing = AppleSpeechSynthesizer()
    ) {
        self.preferences = preferences
        self.synthesizer = synthesizer
        preferences.migrateLegacyAnkiSpeechSettingsIfNeeded()
        enabled = preferences.speechEnabled
        voiceIdentifier = preferences.speechVoiceIdentifier
        rate = preferences.speechRate
        japaneseVoices = AppleSpeechVoices.japanese()
        super.init()
    }

    var configuration: SpeechSettings {
        SpeechSettings(enabled: enabled, voiceIdentifier: voiceIdentifier, rate: rate)
    }

    var previewMessage: String? {
        if japaneseVoices.isEmpty {
            return LocalSpeechSynthesisError.japaneseVoiceUnavailable.localizedDescription
        }
        if let voiceIdentifier,
           !japaneseVoices.contains(where: { $0.id == voiceIdentifier }) {
            return "The selected voice is unavailable; the default Japanese voice will be used."
        }
        if case .failed(let message) = previewState {
            return message
        }
        return nil
    }

    var previewState: AudioPreviewState {
        playbackState(for: Self.settingsPreviewKey)
    }

    func preview() {
        togglePlayback(text: "食べる", key: Self.settingsPreviewKey)
    }

    func playbackState(for key: String) -> AudioPreviewState {
        activePlaybackKey == key ? activePlaybackState : .idle
    }

    func togglePlayback(text: String, key: String) {
        guard enabled, !text.isEmpty else { return }
        if activePlaybackKey == key {
            switch activePlaybackState {
            case .generating, .playing:
                stopPlayback()
                return
            case .idle, .failed:
                break
            }
        }

        stopPlayback()
        activePlaybackKey = key
        activePlaybackState = .generating
        let cacheKey = SpeechCacheKey(
            text: text,
            voiceIdentifier: voiceIdentifier,
            rate: rate
        )
        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data: Data
                if let cached = audioCache[cacheKey] {
                    data = cached
                } else {
                    let audio = try await synthesizer.synthesize(
                        text: text,
                        voiceIdentifier: cacheKey.voiceIdentifier,
                        rate: cacheKey.rate
                    )
                    data = audio.data
                    cache(data, for: cacheKey)
                }
                try Task.checkCancellation()
                guard activePlaybackKey == key else { return }
                guard let sound = NSSound(data: data) else {
                    throw LocalSpeechSynthesisError.encodingFailed("preview playback failed")
                }
                playbackSound = sound
                sound.delegate = self
                guard sound.play() else {
                    throw LocalSpeechSynthesisError.encodingFailed("preview playback failed")
                }
                activePlaybackState = .playing
            } catch is CancellationError {
                if activePlaybackKey == key { clearPlaybackState() }
            } catch {
                if activePlaybackKey == key {
                    playbackSound = nil
                    activePlaybackState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        guard playbackSound === sound else { return }
        clearPlaybackState()
    }

    func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        playbackSound?.delegate = nil
        playbackSound?.stop()
        playbackSound = nil
        clearPlaybackState()
    }

    private func clearPlaybackState() {
        activePlaybackKey = nil
        activePlaybackState = .idle
    }

    private func cache(_ data: Data, for key: SpeechCacheKey) {
        if audioCache[key] == nil {
            cacheOrder.append(key)
        }
        audioCache[key] = data
        while cacheOrder.count > 32 {
            audioCache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}

private struct SpeechCacheKey: Hashable {
    let text: String
    let voiceIdentifier: String?
    let rate: Double
}
