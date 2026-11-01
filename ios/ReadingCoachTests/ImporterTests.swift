import ReadingCore
import XCTest
@testable import ReadingCoach

final class ImporterTests: XCTestCase {
    func testNLTokenizerPreservesAbbreviationAndDistinctDuplicateIDs() throws {
        let snapshot = try ArticleImporter.snapshot(blocks: [(.paragraph, "Dr. Smith said, “It’s ready.” It’s ready. 😀 We can read it!")])
        let resolver = SourceResolver(snapshot: snapshot)
        let sources = try resolver.allSentenceRefs.map(resolver.resolve)
        XCTAssertFalse(sources.isEmpty)
        XCTAssertEqual(Set(snapshot.blocks.flatMap(\.sentences).map(\.id)).count, sources.count)
        XCTAssertTrue(sources.contains { $0.text.contains("Dr. Smith") })
        for source in sources {
            let range = try XCTUnwrap(source.ref.rangeUTF16)
            XCTAssertEqual(try range.substring(in: snapshot.blocks[0].text), source.text)
        }
    }

    func testSnapshotRoundTripKeepsSentenceIDsAndOriginalText() throws {
        let snapshot = try ArticleImporter.snapshot(blocks: [(.paragraph, "Same sentence. Same sentence.")])
        let restored = try JSONDecoder().decode(ArticleSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(snapshot.blocks[0].sentences.count, 2)
        XCTAssertNotEqual(snapshot.blocks[0].sentences[0].id, snapshot.blocks[0].sentences[1].id)
    }

    func testReimportUsesNewSnapshotAndDoesNotAliasOldReferences() throws {
        let first = try ArticleImporter.snapshot(articleID: "article", blocks: [(.paragraph, "A sentence.")])
        let second = try ArticleImporter.snapshot(articleID: "article", blocks: [(.paragraph, "A sentence.")])
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.contentHash, second.contentHash)
        XCTAssertThrowsError(try SourceResolver(snapshot: second).resolve(SourceResolver(snapshot: first).allSentenceRefs[0]))
    }

    func testWordCountingVersionExcludesCodeAndKeepsCompounds() throws {
        let snapshot = try ArticleImporter.snapshot(blocks: [(.paragraph, "It’s a well-tested reader."), (.code, "let ignored = true")])
        XCTAssertEqual(ArticleImporter.wordCount(snapshot), 4)
    }
}
