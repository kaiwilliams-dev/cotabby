import Foundation

/// File overview:
/// A writer's own spelling knowledge, as one immutable value: words they use on purpose, typo fixes
/// they have confirmed, and phrases they repeat. It is pure data plus lookup rules, so the spell
/// checker, the typo gate and the prompt builder can all consult the same value without knowing where
/// it came from (a bundled seed, a file on disk, or a test).
///
/// Why it exists: `NSSpellChecker` knows English, not Kai's `Caseo`, `Julz` or `Synara`. Without this
/// it flags those as typos (suppressing completions) and can even auto-"fix" them. Equally, a fix he
/// has confirmed (`liek` -> `like`) should apply even where the system guess is weaker.
///
/// Lifetime: built by `PersonalVocabularyStore`, replaced wholesale whenever the file changes.
nonisolated struct PersonalVocabulary: Equatable, Sendable {
    /// Words spelled this way on purpose, original casing (`Caseo`, `MCP`) for prompt text.
    private(set) var displayWords: [String]
    /// Lowercased lookup set derived from `displayWords`.
    private(set) var knownWords: Set<String>
    /// Confirmed fixes: lowercased typo -> correct word (lowercase unless it is a name).
    private(set) var corrections: [String: String]
    /// Phrases the writer repeats; fed to the prompt as style/vocabulary context.
    private(set) var phrases: [String]

    static let empty = PersonalVocabulary(words: [], corrections: [:], phrases: [])

    init(words: [String], corrections: [String: String], phrases: [String]) {
        var seen = Set<String>()
        displayWords = words.filter { word in
            let key = word.lowercased()
            return !word.isEmpty && seen.insert(key).inserted
        }
        knownWords = seen
        // A word the writer declared deliberate can never also be a typo to "fix".
        self.corrections = corrections.reduce(into: [:]) { result, pair in
            let typo = pair.key.lowercased()
            if !seen.contains(typo), !pair.value.isEmpty, pair.value.lowercased() != typo {
                result[typo] = pair.value
            }
        }
        self.phrases = phrases
    }

    func isKnown(_ word: String) -> Bool {
        knownWords.contains(word.lowercased())
    }

    func correction(for word: String) -> String? {
        corrections[word.lowercased()]
    }

    /// Later sources win on conflicts, so the writer's own file overrides the bundled seed.
    func merging(_ other: PersonalVocabulary) -> PersonalVocabulary {
        PersonalVocabulary(
            words: displayWords + other.displayWords,
            corrections: corrections.merging(other.corrections) { _, new in new },
            phrases: phrases + other.phrases.filter { !phrases.contains($0) }
        )
    }

    /// A short note for the completion prompt so the model spells the writer's names and jargon the
    /// way they do. Bounded: prompts are character-budgeted, and a long word list would crowd out the
    /// text being continued.
    func promptNote(maxCharacters: Int = 700) -> String? {
        var parts: [String] = []
        var budget = maxCharacters
        if !displayWords.isEmpty {
            var included: [String] = []
            for word in displayWords {
                let cost = word.count + 2
                if budget - cost < maxCharacters / 4 { break }
                included.append(word)
                budget -= cost
            }
            parts.append("Names and terms this writer uses: " + included.joined(separator: ", ") + ".")
        }
        if !phrases.isEmpty, budget > 80 {
            var included: [String] = []
            for phrase in phrases {
                let cost = phrase.count + 3
                if budget - cost < 0 { break }
                included.append("\"\(phrase)\"")
                budget -= cost
            }
            if !included.isEmpty { parts.append("Phrases they often write: " + included.joined(separator: ", ") + ".") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - Decoding

    private struct FileShape: Decodable {
        var words: [String]?
        var corrections: [String: String]?
        var phrases: [String]?
    }

    /// Decodes the on-disk JSON (`{"words": [...], "corrections": {...}, "phrases": [...]}`). Every
    /// key is optional so a hand-edited or partial file still loads; malformed JSON returns nil and the
    /// caller keeps its previous value rather than losing the writer's vocabulary.
    static func decode(_ data: Data) -> PersonalVocabulary? {
        guard let shape = try? JSONDecoder().decode(FileShape.self, from: data) else { return nil }
        return PersonalVocabulary(
            words: shape.words ?? [], corrections: shape.corrections ?? [:], phrases: shape.phrases ?? []
        )
    }
}
