import XCTest
@testable import Cotabby

final class PersonalVocabularyTests: XCTestCase {
    func test_knownWordsAreCaseInsensitive_andNeverBecomeCorrections() {
        let vocabulary = PersonalVocabulary(
            words: ["Caseo", "Julz"], corrections: ["caseo": "casino", "liek": "like"], phrases: []
        )
        XCTAssertTrue(vocabulary.isKnown("caseo"))
        XCTAssertTrue(vocabulary.isKnown("JULZ"))
        XCTAssertNil(vocabulary.correction(for: "Caseo"), "a deliberate word is never a typo")
        XCTAssertEqual(vocabulary.correction(for: "Liek"), "like")
    }

    func test_merging_laterSourceWinsOnConflict() {
        let seed = PersonalVocabulary(words: [], corrections: ["teh": "the", "recieve": "receive"], phrases: ["a b"])
        let personal = PersonalVocabulary(words: ["Teh"], corrections: ["recieve": "receive!"], phrases: ["a b", "c d"])
        let merged = seed.merging(personal)
        XCTAssertNil(merged.correction(for: "teh"), "writer declared Teh deliberate")
        XCTAssertEqual(merged.correction(for: "recieve"), "receive!")
        XCTAssertEqual(merged.phrases, ["a b", "c d"])
    }

    func test_decode_acceptsPartialFiles_andRejectsMalformed() {
        let partial = Data(#"{"corrections": {"liek": "like"}}"#.utf8)
        XCTAssertEqual(PersonalVocabulary.decode(partial)?.correction(for: "liek"), "like")
        XCTAssertNotNil(PersonalVocabulary.decode(Data("{}".utf8)))
        XCTAssertNil(PersonalVocabulary.decode(Data("not json".utf8)))
    }

    func test_promptNote_isBoundedAndNilWhenEmpty() {
        XCTAssertNil(PersonalVocabulary.empty.promptNote())
        let many = (0..<500).map { "Word\($0)" }
        let vocabulary = PersonalVocabulary(words: many, corrections: [:], phrases: ["we need to"])
        let note = vocabulary.promptNote(maxCharacters: 300)
        XCTAssertNotNil(note)
        XCTAssertLessThanOrEqual(note?.count ?? 0, 420)
        XCTAssertTrue(note?.contains("Word0") == true)
    }

    func test_curatedFix_bypassesEditDistanceButNotRejection() {
        func confident(rejected: Set<String> = [], curated: Bool) -> Bool {
            AutoCorrectionPolicy.isConfident(
                .init(typo: "nwo", correction: "now", precedingText: "see nwo ", glossary: "",
                      rejectedTypos: rejected, isCurated: curated),
                delimiter: " ")
        }
        XCTAssertTrue(confident(curated: true))
        XCTAssertFalse(confident(rejected: ["nwo"], curated: true))
        // A far-fetched curated pair still applies (reviewed), while the same pair uncurated does not.
        let far = AutoCorrectionPolicy.Candidate(
            typo: "gonna", correction: "garden", precedingText: "i am gonna ", glossary: "",
            rejectedTypos: [], isCurated: false)
        XCTAssertFalse(AutoCorrectionPolicy.isConfident(far, delimiter: " "))
    }

    func test_typoGate_appliesCuratedFixAtSpace() {
        let decision = TypoGate.resolve(
            precedingText: "ok so thigns ",
            settings: .init(suppressCompletionsOnTypo: true, offerTypoCorrections: true,
                            automaticallyFixTypos: true, curatedFixes: ["thigns": "things"]),
            isTypo: { $0 == "thigns" }, bestCorrection: { _ in "things" })
        XCTAssertEqual(decision, .applyCorrection(word: "thigns", correctedWord: "things"))
    }
}
