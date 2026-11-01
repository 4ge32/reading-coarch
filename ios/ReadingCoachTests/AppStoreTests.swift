import ReadingCore
import SwiftData
import XCTest
@testable import ReadingCoach

@MainActor
final class AppStoreTests: XCTestCase {
    private func makeStore() throws -> (ReadingStore, ModelContainer) {
        let container = try ModelContainer(for: StoredArticle.self, ProcessedImport.self, URLBookmark.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return (ReadingStore(context: container.mainContext), container)
    }

    func testStoreRetainsContainerAfterFactoryReturns() throws {
        weak var containerReference: ModelContainer?
        let store: ReadingStore = try {
            let container = try ModelContainer(for: StoredArticle.self, ProcessedImport.self, URLBookmark.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            containerReference = container
            return ReadingStore(context: container.mainContext)
        }()
        XCTAssertNotNil(containerReference)
        let article = try store.add(title: "Sample", sourceURL: nil, blocks: [(.paragraph, "One sentence.")])
        let ref = try SourceResolver(snapshot: article.snapshot()).allSentenceRefs[0]
        store.toggleMark(ref, article: article)
        XCTAssertEqual(store.activity(article).marks.filter(\.active).count, 1)
        withExtendedLifetime(store) {}
    }

    func testMarkTogglingIsLocalAndKeepsConversationEmpty() throws {
        let (store, _) = try makeStore()
        let article = try store.add(title: "Sample", sourceURL: nil, blocks: [(.paragraph, "A sentence. Another sentence.")])
        let ref = try SourceResolver(snapshot: article.snapshot()).allSentenceRefs[0]
        store.toggleMark(ref, article: article)
        XCTAssertEqual(store.activity(article).marks.filter(\.active).count, 1)
        XCTAssertTrue(store.activity(article).turns.isEmpty)
        store.toggleMark(ref, article: article)
        XCTAssertTrue(store.activity(article).marks.filter(\.active).isEmpty)
        XCTAssertEqual(store.activity(article).marks.count, 1, "Unmark must retain history")
    }

    func testPersistedActivityCanBeReadFromNewContext() throws {
        let (store, container) = try makeStore()
        let article = try store.add(title: "Sample", sourceURL: nil, blocks: [(.paragraph, "One sentence.")])
        let ref = try SourceResolver(snapshot: article.snapshot()).allSentenceRefs[0]
        store.toggleMark(ref, article: article)
        let restoredStore = ReadingStore(context: ModelContext(container))
        let restored = try XCTUnwrap(restoredStore.articles.first)
        XCTAssertEqual(restoredStore.activity(restored).marks.first?.source, ref)
        XCTAssertEqual(try article.snapshot(), try restored.snapshot())
    }

    func testNewSnapshotDoesNotMoveMarks() throws {
        let (store, _) = try makeStore()
        let url = try XCTUnwrap(URL(string: "https://example.com/article"))
        let first = try store.add(title: "Sample", sourceURL: url, blocks: [(.paragraph, "One sentence.")])
        let ref = try SourceResolver(snapshot: first.snapshot()).allSentenceRefs[0]
        store.toggleMark(ref, article: first)
        let second = try store.add(title: "Reimport", sourceURL: url, blocks: [(.paragraph, "One sentence.")])
        XCTAssertEqual(first.articleID, second.articleID)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(store.activity(second).marks.isEmpty)
    }

    func testReadingAndTutoringTimingNeverOverlap() throws {
        let (store, _) = try makeStore()
        let article = try store.add(title: "Sample", sourceURL: nil, blocks: [(.paragraph, "One sentence.")])
        store.beginReader(article)
        store.setTiming("tutor", article: article)
        store.setTiming("listen", article: article)
        store.flushTiming()
        let segments = try XCTUnwrap(store.activity(article).readingRuns.first).segments
        XCTAssertEqual(segments.map(\.kind), ["read", "tutor", "listen"])
        for pair in zip(segments, segments.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.endedAt, pair.1.startedAt) }
    }

    func testCompletedReadingPersistsVersionAndFreezesItsNumeratorAndSegments() throws {
        let (store, _) = try makeStore()
        let article = try store.add(title: "Sample", sourceURL: nil, blocks: [(.paragraph, "A short sentence.")])
        store.beginReader(article)
        store.setTiming("listen", article: article)
        store.completeReading(article)
        let completed = try XCTUnwrap(store.activity(article).readingRuns.first)
        XCTAssertEqual(completed.completedWordCount, 3)
        XCTAssertEqual(completed.wordCountVersion, "unicode-letters-apostrophe-hyphen-v1")
        XCTAssertTrue(completed.heardSource)
        store.setTiming("tutor", article: article)
        store.flushTiming()
        XCTAssertEqual(store.activity(article).readingRuns.first?.segments.count, completed.segments.count)
        store.beginReader(article)
        XCTAssertEqual(store.activity(article).readingRuns.count, 2)
        XCTAssertEqual(store.activity(article).readingRuns.last?.kind, "reread")
        XCTAssertEqual(store.activity(article).readingRuns.first?.completedWordCount, completed.completedWordCount)
    }
}
