import Foundation

/// File overview:
/// Loads the writer's `PersonalVocabulary` and keeps it fresh without any maintenance step.
///
/// Two sources are merged, the second winning: a small bundled seed of universally common typos
/// (`PersonalVocabularySeed.json`, safe to ship), then the writer's own file at
/// `~/Library/Application Support/Cotabby/personal-vocabulary.json`. The personal file never lives in
/// the repository; it is created and updated by local tooling and may also be edited by hand.
///
/// Freshness: `current` compares the file's modification date (at most once every few seconds) and
/// reloads when it changed, so an updated list takes effect while the app runs. A missing or malformed
/// file keeps the last good value.
@MainActor
final class PersonalVocabularyStore {
    private let fileURL: URL
    private let seed: PersonalVocabulary
    private var loaded: PersonalVocabulary
    private var lastModified: Date?
    private var lastChecked: Date = .distantPast
    private let checkInterval: TimeInterval

    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cotabby", isDirectory: true)
            .appendingPathComponent("personal-vocabulary.json")
    }

    init(fileURL: URL = PersonalVocabularyStore.defaultFileURL, bundle: Bundle = .main, checkInterval: TimeInterval = 5) {
        self.fileURL = fileURL
        self.checkInterval = checkInterval
        let seedData = bundle.url(forResource: "PersonalVocabularySeed", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
        seed = seedData.flatMap(PersonalVocabulary.decode) ?? .empty
        loaded = seed
        reloadIfNeeded(force: true)
    }

    /// The vocabulary to use right now. Cheap: a stat call at most every `checkInterval` seconds.
    var current: PersonalVocabulary {
        reloadIfNeeded(force: false)
        return loaded
    }

    private func reloadIfNeeded(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastChecked) >= checkInterval else { return }
        lastChecked = now
        // FileManager, not `URL.resourceValues`: a URL caches its resource values, which would hide
        // every later edit of the file from this long-lived store.
        let modified = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        guard force || modified != lastModified else { return }
        lastModified = modified
        guard let modified, let data = try? Data(contentsOf: fileURL),
              let personal = PersonalVocabulary.decode(data) else {
            if modified == nil { loaded = seed }
            return
        }
        loaded = seed.merging(personal)
    }
}
