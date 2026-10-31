import XCTest
@testable import ReadingCoach

final class ImportInboxTests: XCTestCase {
    private var root: URL!
    private var inbox: ImportInbox!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        inbox = ImportInbox(directory: root.appendingPathComponent("ImportInbox", isDirectory: true))
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testReadIsNonDestructiveUntilConfirmedAcknowledgement() throws {
        let job = sample()
        try inbox.write(job)
        XCTAssertEqual(try inbox.loadPending().jobs.map(\.id), [job.id])
        // Simulate an app restart / failed database commit: merely reading never consumes the job.
        let reopened = ImportInbox(directory: inbox.directory)
        XCTAssertEqual(try reopened.loadPending().jobs.map(\.id), [job.id])
        XCTAssertEqual(try reopened.loadPending().jobs.first?.blocks, job.blocks)
        try reopened.acknowledge(job.id)
        XCTAssertTrue(try reopened.loadPending().jobs.isEmpty)
        // Cleanup can safely retry after a prior successful acknowledgement.
        XCTAssertNoThrow(try reopened.acknowledge(job.id))
    }

    func testDuplicateJobCannotOverwritePreviouslySavedInput() throws {
        let job = sample()
        try inbox.write(job)
        let replacement = ImportJob(id: job.id, title: "Replacement", blocks: [ImportedBlock(kind: .paragraph, text: "Different content.")], status: .extracted)
        XCTAssertThrowsError(try inbox.write(replacement))
        XCTAssertEqual(try inbox.loadPending().jobs.first?.title, job.title)
    }

    func testCorruptInputIsRetainedWithoutHidingOtherPendingJobs() throws {
        let job = sample()
        try inbox.write(job)
        let corruptURL = inbox.directory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("not a JSON import job".utf8).write(to: corruptURL)
        let result = try inbox.loadPending()
        XCTAssertEqual(result.jobs.map(\.id), [job.id])
        XCTAssertEqual(result.unreadableFileCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))
    }

    func testJobIDMustMatchItsFilename() throws {
        let job = sample()
        try inbox.write(job)
        let original = inbox.directory.appendingPathComponent(job.id.uuidString + ".json")
        let renamed = inbox.directory.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.moveItem(at: original, to: renamed)
        let result = try inbox.loadPending()
        XCTAssertTrue(result.jobs.isEmpty)
        XCTAssertEqual(result.unreadableFileCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
    }

    func testURLOnlyJobNeverClaimsToContainAnArticle() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/article"))
        let job = ImportJob(title: "URL only", sourceURL: url, blocks: [], status: .urlOnly)
        try inbox.write(job)
        let reloaded = try XCTUnwrap(inbox.loadPending().jobs.first)
        XCTAssertEqual(reloaded.status, .urlOnly)
        XCTAssertTrue(reloaded.blocks.isEmpty)
        XCTAssertEqual(reloaded.sourceURL, url)
        XCTAssertThrowsError(try inbox.write(ImportJob(title: "Not extracted", blocks: [], status: .extracted)))
    }

    func testRejectsUnsafeURLAndOversizedContent() throws {
        for rawURL in ["javascript:alert(1)", "file:///etc/passwd", "https://user:secret@example.com/article"] {
            XCTAssertThrowsError(try inbox.write(ImportJob(title: "Unsafe", sourceURL: URL(string: rawURL), blocks: [], status: .urlOnly)))
        }
        let huge = ImportJob(title: "Too large", blocks: [ImportedBlock(kind: .paragraph, text: String(repeating: "x", count: 4_000_001))], status: .extracted)
        XCTAssertThrowsError(try inbox.write(huge))
    }

    func testDeletingAllInboxDataLeavesNoPendingImports() throws {
        try inbox.write(sample())
        try inbox.removeAll()
        XCTAssertTrue(try inbox.loadPending().jobs.isEmpty)
        XCTAssertNoThrow(try inbox.removeAll())
    }

    private func sample() -> ImportJob {
        ImportJob(title: "Original article", sourceURL: URL(string: "https://example.com/article"),
                  blocks: [ImportedBlock(kind: .heading, text: "A careful review"), ImportedBlock(kind: .paragraph, text: "A test may pass without proving every requirement. 🧠")], status: .extracted)
    }
}
