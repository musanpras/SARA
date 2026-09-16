import Foundation

/// What a wake-word engine reports.
public enum WakeWordEvent: Sendable {
    /// The wake phrase was heard. `trailingCommand` carries anything the user
    /// said *after* the phrase in the same breath ("Hey SARA, what's next?"),
    /// so the coordinator can use it instead of opening a fresh capture and
    /// losing those words. `nil` when the phrase stood alone.
    case detected(trailingCommand: String?)
    case failed(SpeechError)
}

/// A wake-word engine, behind a protocol so the on-device recogniser used for
/// the MVP can later be swapped for a dedicated keyword-spotting model without
/// the coordinator, ConversationManager, or the AI layer changing.
///
/// Implementations must run locally and must not stream audio to a cloud
/// service — the whole point of the wake word is that continuous listening
/// never leaves the device.
public protocol WakeWordDetecting: Sendable {
    /// Begins listening for the wake phrase. The stream yields once when the
    /// phrase is detected (then finishes), or a failure, or simply finishes if
    /// stopped. It never yields raw audio or partial transcripts upward.
    func start() async -> AsyncStream<WakeWordEvent>
    /// Stops listening and releases the microphone.
    func stop() async
}

/// Pure wake-phrase recognition over a transcript.
///
/// Separated from any recogniser so the matching rules — normalisation, where
/// the phrase may appear, and how the command is split off — are testable on
/// plain strings. Both the wake engine (scanning its partials) and the command
/// path (defensively stripping a leaked phrase) use it, so a phrase can never
/// end up inside an ActionPlan's input.
public struct WakeWordMatcher: Sendable {
    /// Normalised tokens of the wake phrase, e.g. ["hey", "sara"].
    private let tokens: [String]

    public init(phrase: String) {
        self.tokens = Self.normalize(phrase)
    }

    public struct Match: Equatable, Sendable {
        /// Text spoken after the wake phrase, trimmed; `nil` if there was none.
        public let trailingCommand: String?
    }

    /// Detects the wake phrase anywhere in `transcript`. When found, returns the
    /// remainder after the phrase as `trailingCommand` (nil if empty).
    ///
    /// Leading words ("hey") must match exactly, but the name is matched
    /// loosely: Apple's recogniser routinely writes "SARA" as "Sarah", "Sara"
    /// or "Zara", and a wake word that only fires on a perfect transcription is
    /// a wake word that mostly does not fire.
    public func match(in transcript: String) -> Match? {
        let words = Self.normalize(transcript)
        guard !tokens.isEmpty, words.count >= tokens.count else { return nil }

        // Scan for the token run. The last occurrence wins, so a repeated
        // "Hey SARA... Hey SARA, do X" keeps only what follows the final one.
        var foundEnd: Int?
        var index = 0
        while index + tokens.count <= words.count {
            if windowMatches(words, startingAt: index) {
                foundEnd = index + tokens.count
            }
            index += 1
        }
        guard let end = foundEnd else { return nil }

        let trailing = words[end...].joined(separator: " ")
        return Match(trailingCommand: trailing.isEmpty ? nil : trailing)
    }

    /// True when the window of `words` at `start` is the wake phrase: every word
    /// but the last exactly, and the last a near-miss of the name.
    private func windowMatches(_ words: [String], startingAt start: Int) -> Bool {
        for offset in 0..<tokens.count {
            let word = words[start + offset]
            let token = tokens[offset]
            let isName = offset == tokens.count - 1
            if isName {
                if !Self.nameMatches(word, token) { return false }
            } else if word != token {
                return false
            }
        }
        return true
    }

    /// Whether a heard word is close enough to the expected name token.
    ///
    /// Accepts an exact hit, one that starts with the name (its plural or
    /// possessive), or one within a single edit — enough to cover the common
    /// mis-hearings of a short name without matching unrelated words.
    static func nameMatches(_ word: String, _ name: String) -> Bool {
        if word == name { return true }
        if name.count >= 4, word.hasPrefix(name) { return true }
        if name.count >= 3, word.hasPrefix(name.prefix(name.count - 1)),
           abs(word.count - name.count) <= 1 { return true }
        return levenshtein(word, name) <= 1
    }

    /// Classic edit distance, small inputs only (single words).
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = Swift.min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    /// Removes a leading wake phrase from a command transcript, if present.
    ///
    /// Used on the command path as a safety net: if the wake engine's audio
    /// bled into the command recogniser, the phrase is stripped here so the
    /// pipeline sees "schedule gym", never "hey sara schedule gym".
    public func stripping(from transcript: String) -> String {
        guard let match = match(in: transcript) else { return transcript }
        return match.trailingCommand ?? ""
    }

    /// Lowercased, punctuation-free word list. The recogniser is inconsistent
    /// about capitalisation and commas around a name, so matching happens on a
    /// canonical form rather than the raw string.
    static func normalize(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
