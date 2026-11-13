import XCTest
@testable import Cotabby

/// Pins the guards that decide whether a spell-checker guess may be applied with no keypress.
/// Every case is pure: no `NSSpellChecker`, no focus snapshot, no settings object.
final class AutoCorrectionPolicyTests: XCTestCase {
    private func confident(
        _ typo: String,
        _ correction: String,
        before: String = "see ",
        delimiter: String = " ",
        glossary: String = "",
        rejected: Set<String> = []
    ) -> Bool {
        AutoCorrectionPolicy.isConfident(
            .init(typo: typo, correction: correction, precedingText: before + typo + delimiter,
                  glossary: glossary, rejectedTypos: rejected),
            delimiter: delimiter
        )
    }

    // MARK: Boundaries

    func test_boundaries_spaceAndSentencePunctuationOnly() {
        for delimiter in [" ", ",", "!", "?", ", ", "! ", "? "] {
            XCTAssertTrue(AutoCorrectionPolicy.allowsBoundary(delimiter), delimiter)
        }
        for delimiter in ["", ";", ":", ".", ". ", "  ", "\n", ",,"] {
            XCTAssertFalse(AutoCorrectionPolicy.allowsBoundary(delimiter), delimiter.debugDescription)
        }
    }

    // MARK: Edit distance

    func test_editDistance_countsAdjacentSwapAsOneEdit() {
        XCTAssertEqual(AutoCorrectionPolicy.editDistance("teh", "the"), 1)
        XCTAssertEqual(AutoCorrectionPolicy.editDistance("recieve", "receive"), 1)
        XCTAssertEqual(AutoCorrectionPolicy.editDistance("definately", "definitely"), 1)
        XCTAssertEqual(AutoCorrectionPolicy.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(AutoCorrectionPolicy.editDistance("", "abc"), 3)
        XCTAssertEqual(AutoCorrectionPolicy.editDistance("same", "same"), 0)
    }

    // MARK: Confidence

    func test_acceptsSmallEditsOnCommonTypos() {
        XCTAssertTrue(confident("teh", "the"))
        XCTAssertTrue(confident("recieve", "receive"))
        XCTAssertTrue(confident("adn", "and", delimiter: ","))
        XCTAssertTrue(confident("dont", "don't", delimiter: "!"))
    }

    func test_shortWordsAllowOnlyOneEdit_longerWordsTwo() {
        XCTAssertFalse(confident("tha", "that, and"))
        XCTAssertFalse(confident("wrld", "world!!"))
        XCTAssertFalse(confident("cmpy", "company"))      // 3 edits
        XCTAssertTrue(confident("compnay", "company"))    // swap = 1 edit
        XCTAssertTrue(confident("adress", "address"))     // 1 edit, 6 letters
        XCTAssertFalse(confident("tehr", "other"))        // 4-letter word, 2+ edits
    }

    func test_rejectsMultiWordOrBlankCorrections() {
        XCTAssertFalse(confident("alot", "a lot"))
        XCTAssertFalse(confident("ofthe", "of the"))
        XCTAssertFalse(confident("teh", ""))
    }

    func test_rejectsNoOpAndTooShortTypos() {
        XCTAssertFalse(confident("teh", "Teh"))
        XCTAssertFalse(confident("hm", "him"))
    }

    func test_midWordCapitalsAndNamesAreNeverTouched() {
        XCTAssertFalse(confident("iPhoen", "iPhone"))
        XCTAssertFalse(confident("McDonlad", "McDonald"))
        // A capitalised word mid-sentence is a name, not a sentence-opening typo.
        XCTAssertFalse(confident("Nakai", "Naked", before: "this is "))
    }

    func test_sentenceOpeningCapitalWordIsCorrectable() {
        XCTAssertTrue(confident("Teh", "The", before: ""))
        XCTAssertTrue(confident("Teh", "The", before: "Done. "))
        XCTAssertTrue(confident("Teh", "The", before: "Done!\n"))
        XCTAssertFalse(confident("Teh", "The", before: "and "))
    }

    func test_wordTheWriterAlreadyUsedIsDeliberate() {
        XCTAssertFalse(confident("teh", "the", before: "teh band played. "))
        XCTAssertFalse(confident("teh", "the", before: "", glossary: "Teh Tarik, Nakai"))
        // The typo itself, just typed, does not count as evidence.
        XCTAssertTrue(confident("teh", "the", before: "hello "))
    }

    func test_rejectedTyposAreNeverAutoAppliedAgain() {
        XCTAssertFalse(confident("teh", "the", rejected: ["teh"]))
        XCTAssertFalse(confident("Teh", "The", before: "", rejected: ["teh"]))
        XCTAssertTrue(confident("recieve", "receive", rejected: ["teh"]))
    }

    // MARK: Undo state

    func test_undoEntryExpiresAndSettles() {
        var state = AutoCorrectionUndoState()
        state.recordFix(typo: "teh", correction: "the", delimiter: " ", at: 100)
        XCTAssertEqual(state.undoableEntry(at: 101)?.typo, "teh")
        XCTAssertNil(state.undoableEntry(at: 100 + AutoCorrectionUndoState.window + 0.1))
        state.settle()
        XCTAssertNil(state.pending)
        XCTAssertTrue(state.rejectedTypos.isEmpty)
    }

    func test_rejectionIsRememberedCaseInsensitively() {
        var state = AutoCorrectionUndoState()
        state.recordFix(typo: "Teh", correction: "The", delimiter: " ", at: 0)
        state.recordRejection(of: "Teh")
        XCTAssertNil(state.pending)
        XCTAssertEqual(state.rejectedTypos, ["teh"])
    }
}
