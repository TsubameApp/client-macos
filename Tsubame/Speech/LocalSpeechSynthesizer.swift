import AVFAudio
import AVFoundation
import CryptoKit
import Foundation

struct LocalSpeechVoice: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let language: String
    let quality: AVSpeechSynthesisVoiceQuality

    var displayName: String {
        switch quality {
        case .premium:
            "\(name) — Premium"
        case .enhanced:
            "\(name) — Enhanced"
        default:
            name
        }
    }
}

struct SynthesizedAudio: Sendable, Equatable {
    let data: Data
    let filename: String
    let mimeType: String
}

enum LocalSpeechSynthesisError: LocalizedError, Sendable, Equatable {
    case japaneseVoiceUnavailable
    case emptyAudio
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .japaneseVoiceUnavailable:
            "Install a Japanese system voice in macOS Accessibility settings."
        case .emptyAudio:
            "macOS speech synthesis returned no audio."
        case .encodingFailed(let message):
            "Could not encode pronunciation audio: \(message)"
        }
    }
}

protocol LocalSpeechSynthesizing: Sendable {
    @MainActor
    func synthesize(
        text: String,
        voiceIdentifier: String?,
        rate: Double
    ) async throws -> SynthesizedAudio
}

enum AppleSpeechVoices {
    static func japanese() -> [LocalSpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("ja") }
            .map {
                LocalSpeechVoice(
                    id: $0.identifier,
                    name: $0.name,
                    language: $0.language,
                    quality: $0.quality
                )
            }
            .sorted {
                if $0.quality != $1.quality {
                    return $0.quality.rawValue > $1.quality.rawValue
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}

@MainActor
final class AppleSpeechSynthesizer: @unchecked Sendable, LocalSpeechSynthesizing {
    private let synthesizer = AVSpeechSynthesizer()

    nonisolated init() {}

    func synthesize(
        text: String,
        voiceIdentifier: String?,
        rate: Double
    ) async throws -> SynthesizedAudio {
        try Task.checkCancellation()
        let voice = try resolvedVoice(identifier: voiceIdentifier)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TsubameSpeech-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pcmURL = directory.appending(path: "speech.caf")
        let outputURL = directory.appending(path: "speech.m4a")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(
            min(max(rate, 0.5), 2)
        )

        let writer = SpeechBufferWriter(url: pcmURL)
        try await withCheckedThrowingContinuation { continuation in
            writer.start(continuation: continuation)
            synthesizer.write(utterance) { buffer in
                writer.consume(buffer)
            }
        }
        try Task.checkCancellation()
        try await exportM4A(from: pcmURL, to: outputURL)
        let data = try Data(contentsOf: outputURL)
        guard !data.isEmpty else { throw LocalSpeechSynthesisError.emptyAudio }
        let digest = SHA256.hash(data: data)
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return SynthesizedAudio(
            data: data,
            filename: "tsubame-audio-v1-\(digest).m4a",
            mimeType: "audio/mp4"
        )
    }

    private func resolvedVoice(identifier: String?) throws -> AVSpeechSynthesisVoice {
        if let identifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier),
           voice.language.hasPrefix("ja") {
            return voice
        }
        guard let voice = AVSpeechSynthesisVoice(language: "ja-JP") else {
            throw LocalSpeechSynthesisError.japaneseVoiceUnavailable
        }
        return voice
    }

    private func exportM4A(from inputURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: inputURL)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw LocalSpeechSynthesisError.encodingFailed("AAC exporter unavailable")
        }
        try await exporter.export(to: outputURL, as: .m4a)
    }
}

private final class SpeechBufferWriter: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var isFinished = false
    private var wroteFrames = false

    init(url: URL) {
        self.url = url
    }

    func start(continuation: CheckedContinuation<Void, any Error>) {
        lock.withLock {
            self.continuation = continuation
        }
    }

    func consume(_ buffer: AVAudioBuffer) {
        lock.withLock {
            guard !isFinished else { return }
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                finish(.failure(LocalSpeechSynthesisError.encodingFailed(
                    "unexpected speech buffer format"
                )))
                return
            }
            guard pcmBuffer.frameLength > 0 else {
                finish(wroteFrames
                    ? .success(())
                    : .failure(LocalSpeechSynthesisError.emptyAudio))
                return
            }
            do {
                if file == nil {
                    file = try AVAudioFile(
                        forWriting: url,
                        settings: pcmBuffer.format.settings
                    )
                }
                try file?.write(from: pcmBuffer)
                wroteFrames = true
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard !isFinished else { return }
        isFinished = true
        file = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
