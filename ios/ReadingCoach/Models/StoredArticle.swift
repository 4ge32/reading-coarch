import Foundation
import ReadingCore
import SwiftData

/// Each row is one immutable source snapshot. Reimport creates a new row.
@Model
final class StoredArticle {
    @Attribute(.unique) var id: String
    var articleID: String
    var title: String
    var sourceURL: String?
    var author: String?
    var createdAt: Date
    private(set) var sourceData: Data
    var activityData: Data

    init(snapshot: ArticleSnapshot, title: String, sourceURL: URL?, author: String? = nil) throws {
        self.id = snapshot.id
        self.articleID = snapshot.articleID
        self.title = title
        self.sourceURL = sourceURL?.absoluteString
        self.author = author
        self.createdAt = snapshot.importedAt
        self.sourceData = try JSONEncoder().encode(snapshot)
        self.activityData = try JSONEncoder().encode(ArticleActivity())
    }

    func snapshot() throws -> ArticleSnapshot { try JSONDecoder().decode(ArticleSnapshot.self, from: sourceData) }
    func activity() throws -> ArticleActivity { try JSONDecoder().decode(ArticleActivity.self, from: activityData) }
}

struct LocalMark: Codable, Identifiable {
    var id = UUID().uuidString
    let source: SourceRef
    var active: Bool
    let createdAt: Date
}

struct StoredTurn: Codable, Identifiable {
    var id = UUID().uuidString
    var requestID: String?
    let role: String
    var text: String
    let source: SourceRef
    let createdAt: Date
    var superseded = false
    var inputModality = "text"
    var assessment: String?
    var practiceID: String?
}

struct EvidenceEntry: Codable, Identifiable {
    var id = UUID().uuidString
    let source: SourceRef
    let kind: String
    let createdAt: Date
    var requestID: String?
    var superseded = false
}

struct LocalTimingSegment: Codable {
    let kind: String
    let startedAt: Date
    var endedAt: Date
    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
}

struct LocalReadingRun: Codable, Identifiable {
    var id = UUID().uuidString
    let kind: String
    let startedAt: Date
    var completedAt: Date?
    var completedWordCount: Int?
    var wordCountVersion = "unicode-letters-apostrophe-hyphen-v1"
    var hasAssistance = false
    var heardSource = false
    var segments: [LocalTimingSegment] = []
    var readSeconds: TimeInterval { segments.filter { $0.kind == "read" }.reduce(0) { $0 + $1.duration } }
}

struct ArticleActivity: Codable {
    var marks: [LocalMark] = []
    var focusedSource: SourceRef?
    var readingPosition: String?
    var lastPlayedSource: SourceRef?
    var sourceHeard: Set<SourceRef> = []
    var turns: [StoredTurn] = []
    var evidence: [EvidenceEntry] = []
    var readingRuns: [LocalReadingRun] = []
    var learningRunID = UUID().uuidString
    var stateRevision = 0
    var learningOrder: [SourceRef] = []
    var reviewMode = false
    var processedToolIDs: Set<String> = []
    var processedRequestIDs: Set<String> = []
    var deferredSources: Set<SourceRef> = []
    var reviewDueAt: [String: Date] = [:]
    var generatedPractice: [PracticeItem] = []
    var learningRun: LearningRun?
    var archivedLearningRuns: [LearningRun] = []
}
