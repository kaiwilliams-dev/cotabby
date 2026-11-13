import XCTest
@testable import Cotabby

@MainActor
final class PersonalVocabularyStoreTests: XCTestCase {
    /// App-hosted tests can crash while deallocating a main-actor object (see CONTRIBUTING). The real
    /// store lives for the whole app run, so tests keep theirs alive for the process instead.
    private static var keepAlive: [PersonalVocabularyStore] = []

    private func makeStore(_ url: URL) -> PersonalVocabularyStore {
        let store = PersonalVocabularyStore(fileURL: url, bundle: Bundle(for: Self.self), checkInterval: 0)
        Self.keepAlive.append(store)
        return store
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pv-\(UUID().uuidString).json")
    }

    func test_missingFile_givesSeedOnly() {
        let store = makeStore(tempURL())
        XCTAssertTrue(store.current.displayWords.isEmpty)
    }

    func test_loadsFile_andReloadsWhenItChanges() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"words":["Caseo"]}"#.utf8).write(to: url)
        let store = makeStore(url)
        XCTAssertTrue(store.current.isKnown("caseo"))

        try Data(#"{"words":["Caseo","Synara"],"corrections":{"liek":"like"}}"#.utf8).write(to: url)
        // Force a distinct modification date even on coarse-timestamp filesystems.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        XCTAssertTrue(store.current.isKnown("synara"))
        XCTAssertEqual(store.current.correction(for: "liek"), "like")
    }

    func test_malformedFile_keepsLastGoodValue() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"words":["Caseo"]}"#.utf8).write(to: url)
        let store = makeStore(url)
        try Data("garbage".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        XCTAssertTrue(store.current.isKnown("caseo"))
    }
}
