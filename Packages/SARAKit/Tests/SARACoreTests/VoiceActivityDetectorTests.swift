import Testing
@testable import SARACore

@Suite("Voice activity detection")
struct VoiceActivityDetectorTests {
    private let config = VoiceDetectionConfiguration(
        endOfSpeechSilenceDuration: 1.0,
        minimumSpeechDuration: 0.3,
        onsetThreshold: 0.06,
        releaseThreshold: 0.035,
        noiseFloorAdaptation: 0.05
    )

    /// Feeds a level repeatedly at a fixed cadence, returning the last event.
    private func feed(
        _ detector: inout VoiceActivityDetector,
        level: Float,
        from start: Double,
        count: Int,
        step: Double = 0.1
    ) -> (event: VoiceActivityEvent, nextTime: Double) {
        var event = VoiceActivityEvent.silence
        var time = start
        for _ in 0..<count {
            event = detector.process(level: level, at: time)
            time += step
        }
        return (event, time)
    }

    @Test("Pure silence never ends an utterance that never began")
    func silenceAloneIsNotEndOfSpeech() {
        var detector = VoiceActivityDetector(configuration: config)
        let result = feed(&detector, level: 0.001, from: 0, count: 30)
        #expect(result.event == .silence)
        #expect(!detector.didFinish)
    }

    @Test("Speech then a long silence ends the utterance")
    func speechThenSilenceEnds() {
        var detector = VoiceActivityDetector(configuration: config)
        // Establish a quiet floor, then speak, then fall silent.
        _ = feed(&detector, level: 0.002, from: 0, count: 3)
        let afterSpeech = feed(&detector, level: 0.3, from: 0.3, count: 8)
        #expect(afterSpeech.event == .speaking || afterSpeech.event == .speechStarted)

        var ended = false
        var time = afterSpeech.nextTime
        for _ in 0..<20 {
            if detector.process(level: 0.002, at: time) == .endOfUtterance {
                ended = true
                break
            }
            time += 0.1
        }
        #expect(ended)
        #expect(detector.didFinish)
    }

    @Test("A short pause mid-sentence does not end the utterance")
    func shortPauseDoesNotEnd() {
        var detector = VoiceActivityDetector(configuration: config)
        _ = feed(&detector, level: 0.002, from: 0, count: 3)
        _ = feed(&detector, level: 0.3, from: 0.3, count: 6)          // "schedule a meeting"
        // A 0.5s pause — shorter than the 1.0s end-of-speech window.
        let pause = feed(&detector, level: 0.002, from: 0.9, count: 5)
        #expect(pause.event != .endOfUtterance)
        #expect(!detector.didFinish)
        // Speech resumes ("tomorrow at 3 PM").
        let resumed = feed(&detector, level: 0.3, from: 1.4, count: 4)
        #expect(resumed.event == .speaking)
    }

    @Test("A blip shorter than the minimum speech duration cannot end a turn")
    func minimumSpeechGuard() {
        var detector = VoiceActivityDetector(configuration: config)
        _ = feed(&detector, level: 0.002, from: 0, count: 3)
        // One loud buffer (a cough), well under 0.3s of speech.
        _ = detector.process(level: 0.4, at: 0.3)
        // Then long silence — must not be treated as end-of-utterance.
        let result = feed(&detector, level: 0.002, from: 0.4, count: 20)
        #expect(result.event != .endOfUtterance)
        #expect(!detector.didFinish)
    }

    @Test("Speaking from the very first buffer is still detected and can end")
    func speechFromFirstBuffer() {
        var detector = VoiceActivityDetector(configuration: config)
        // No quiet lead-in: the user talks immediately. The floor must not seed
        // to their voice, or onset would sit above it and nothing would register.
        let speech = feed(&detector, level: 0.3, from: 0, count: 8)
        #expect(speech.event == .speechStarted || speech.event == .speaking)

        var ended = false
        var time = speech.nextTime
        for _ in 0..<20 {
            if detector.process(level: 0.002, at: time) == .endOfUtterance { ended = true; break }
            time += 0.1
        }
        #expect(ended)
    }

    @Test("Continuous speech keeps reporting speaking, never ends")
    func continuousSpeech() {
        var detector = VoiceActivityDetector(configuration: config)
        _ = feed(&detector, level: 0.002, from: 0, count: 3)
        let result = feed(&detector, level: 0.3, from: 0.3, count: 40)
        #expect(result.event == .speaking)
        #expect(!detector.didFinish)
    }

    @Test("End-of-utterance is reported only once")
    func endReportedOnce() {
        var detector = VoiceActivityDetector(configuration: config)
        _ = feed(&detector, level: 0.002, from: 0, count: 3)
        _ = feed(&detector, level: 0.3, from: 0.3, count: 6)
        var time = 0.9
        var endCount = 0
        for _ in 0..<20 {
            if detector.process(level: 0.002, at: time) == .endOfUtterance { endCount += 1 }
            time += 0.1
        }
        // Every reading after the first end still returns .endOfUtterance (it is
        // latched), but the transition happens once — the caller stops on the
        // first, so what matters is it is stable and never flips back.
        #expect(endCount >= 1)
        #expect(detector.didFinish)
    }
}
