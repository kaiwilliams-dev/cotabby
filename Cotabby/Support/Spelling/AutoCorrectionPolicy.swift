import Foundation

/// File overview:
/// Pure confidence policy for the *automatic* typo fix (`automaticallyFixTypos`). The spell checker
/// answers "is this a misspelling and what is its best guess?"; this file answers the stricter
/// question "is that guess safe to apply without the writer pressing a key?".
///
/// Why it is its own boundary: an offered green correction costs the writer one Tab to reject, but an
/// automatic fix silently rewrites their text, so a wrong guess is a visible mistake. Keeping the rules
/// here (no `NSSpellChecker`, no AX, no settings object) makes each guard unit-testable and keeps
/// `TypoGate` a thin decision table. A word that fails any guard is not dropped: the gate falls back
/// to offering the same correction as a green Tab-to-accept suggestion.
///
/// Owned by nobody: all members are static, deterministic and `nonisolated`.
nonisolated enum AutoCorrectionPolicy {
    /// Delimiters after which a word counts as committed enough to rewrite. A space and the
    /// sentence-ending marks `, ! ?` (each optionally followed by one space) are unambiguous word
    /// boundaries. `;` and `:` are excluded because `http:` / `key:` are routinely typed mid-token, and
    /// `.` is not produced by `CaretWordContext.committedWord` at all (`file.txt`, `example.com`).
    static func allowsBoundary(_ delimiter: String) -> Bool {
        switch delimiter {
        case " ", ",", "!", "?", ", ", "! ", "? ":
            return true
        default:
            return false
        }
    }

    /// Everything the confidence decision needs, grouped so call sites stay readable.
    struct Candidate {
        /// The misspelled word exactly as typed.
        let typo: String
        /// The spell checker's best single guess.
        let correction: String
        /// The text before the caret, including the typo and its delimiter. Used to tell whether the
        /// word opens a sentence and whether the writer has already used this spelling elsewhere.
        let precedingText: String
        /// The writer's own glossary text (custom vocabulary / names), if any.
        let glossary: String
        /// Lowercased typos the writer already reverted once; never auto-applied again this session.
        let rejectedTypos: Set<String>
    }

    static func isConfident(_ candidate: Candidate, delimiter: String) -> Bool {
        let typo = candidate.typo
        let correction = candidate.correction
        guard typo.count >= 3, isSingleWord(correction) else { return false }
        guard correction.lowercased() != typo.lowercased() else { return false }
        guard !candidate.rejectedTypos.contains(typo.lowercased()) else { return false }
        guard casingIsSafe(typo: typo, precedingText: candidate.precedingText, delimiter: delimiter) else {
            return false
        }
        guard !writerUsesSpelling(candidate) else { return false }

        let distance = editDistance(typo.lowercased(), correction.lowercased())
        return distance >= 1 && distance <= maximumEditDistance(forTypoLength: typo.count)
    }

    /// Short words have too many near neighbours (`teh` is one swap from `the` but `tha` is one edit
    /// from five words), so the budget grows with length: 3-4 letters allow one edit, 5+ allow two.
    static func maximumEditDistance(forTypoLength length: Int) -> Int {
        length <= 4 ? 1 : 2
    }

    /// A correction must be one plain word. `NSSpellChecker` sometimes answers with a two-word split
    /// ("a lot", "of the"); splitting is a different edit from fixing a typo and is never automatic.
    static func isSingleWord(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isLetter || CaretWordContext.isConnector($0) }
    }

    /// Names and brands are the classic false positive: `Nakai` is "misspelled" and one edit from
    /// `Naked`. A capital letter inside a word (`iPhone`, `McDonald`) is never touched; a leading
    /// capital is only touched when the word opens a sentence, where `Teh` genuinely means `The`.
    static func casingIsSafe(typo: String, precedingText: String, delimiter: String) -> Bool {
        let tail = typo.dropFirst()
        if tail.contains(where: { $0.isUppercase }) { return false }
        guard typo.first?.isUppercase == true else { return true }
        let suffix = typo + delimiter
        guard precedingText.hasSuffix(suffix) else { return false }
        let before = precedingText.dropLast(suffix.count)
        let trimmed = before.reversed().drop(while: { $0 == " " || $0 == "\t" })
        guard let last = trimmed.first else { return true }
        return last == "\n" || ".!?".contains(last)
    }

    /// True when the writer already spelled the word this way earlier in the field or in their glossary
    /// (a coined term, a name, an in-joke). Repeating a "typo" is strong evidence it is deliberate.
    static func writerUsesSpelling(_ candidate: Candidate) -> Bool {
        let key = candidate.typo.lowercased()
        let suffix = candidate.typo + (candidate.precedingText.hasSuffix(candidate.typo + " ") ? " " : "")
        var text = String(candidate.precedingText.suffix(4000))
        if let range = text.range(of: suffix, options: [.backwards, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        let corpus = text + " " + candidate.glossary.prefix(1300)
        let words = corpus.split(whereSeparator: { !$0.isLetter && !CaretWordContext.isConnector($0) })
        return words.contains { $0.lowercased() == key }
    }

    /// Optimal-string-alignment distance: insertions, deletions, substitutions and adjacent
    /// transposition each cost 1, so the commonest typing error (`teh` for `the`) is a single edit.
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previousPrevious = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [Int](repeating: 0, count: b.count + 1)
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], previousPrevious[j - 2] + 1)
                }
            }
            previousPrevious = previous
            previous = current
        }
        return previous[b.count]
    }
}

/// Short-lived memory of the one automatic fix the writer may still want to take back.
///
/// The coordinator records an entry right after it rewrites a word. The very next key decides its
/// fate: Backspace or Cmd+Z reverts to what was typed (and remembers the rejection), anything else
/// accepts the fix. It lives only in memory, expires quickly, and holds one word, never the field text.
nonisolated struct AutoCorrectionUndoState: Equatable {
    struct Entry: Equatable {
        let typo: String
        let correction: String
        /// The delimiter the writer typed and Cotabby re-typed after the correction.
        let delimiter: String
        let expiresAt: TimeInterval
    }

    /// How long after an automatic fix an immediate Backspace / Cmd+Z still counts as "undo".
    static let window: TimeInterval = 4

    private(set) var pending: Entry?
    /// Lowercased typos the writer reverted this session. Auto-fix never touches them again, which is
    /// also what stops an undo from being instantly re-corrected by the next prediction cycle.
    private(set) var rejectedTypos: Set<String> = []

    mutating func recordFix(typo: String, correction: String, delimiter: String, at time: TimeInterval) {
        pending = Entry(typo: typo, correction: correction, delimiter: delimiter, expiresAt: time + Self.window)
    }

    /// The fix to take back for a key press at `time`, or nil. Does not mutate; call `consume` once the
    /// revert was actually performed.
    func undoableEntry(at time: TimeInterval) -> Entry? {
        guard let pending, pending.expiresAt > time else { return nil }
        return pending
    }

    /// Any key other than an undo gesture settles the fix.
    mutating func settle() {
        pending = nil
    }

    mutating func recordRejection(of typo: String) {
        rejectedTypos.insert(typo.lowercased())
        pending = nil
    }
}
