import AVFoundation
import Foundation
import SARACore

/// SARA's voice, using the system speech synthesiser.
///
/// `speak` returns when the utterance finishes, so a caller can sequence
/// speech against UI state instead of guessing at timing.
public final class SystemVoiceOutputProvider: NSObject, VoiceOutputProvider, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var pending: CheckedContinuation<Void, Never>?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await stop()
        configureSessionForPlayback()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.preferredVoice()
        // Slightly above the default: calm, but not slow enough to feel laboured.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0

        await withCheckedContinuation { continuation in
            lock.lock()
            pending = continuation
            lock.unlock()
            synthesizer.speak(utterance)
        }
    }

    public func stop() async {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        resumePending()
    }

    private func resumePending() {
        lock.lock()
        let continuation = pending
        pending = nil
        lock.unlock()
        continuation?.resume()
    }

    private func configureSessionForPlayback() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
    }

    /// Prefers an enhanced voice in the user's language when one is installed,
    /// so SARA sounds the same regardless of which model answered.
    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }

        return candidates.first { $0.quality == .premium }
            ?? candidates.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: language)
    }
}

extension SystemVoiceOutputProvider: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resumePending()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resumePending()
    }
}
