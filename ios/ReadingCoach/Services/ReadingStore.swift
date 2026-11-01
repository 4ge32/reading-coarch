import Foundation
import ReadingCore
import SwiftData
import SwiftUI

@MainActor
final class ReadingStore: ObservableObject {
    @Published private(set) var articles: [StoredArticle] = []
    @Published private(set) var urlBookmarks: [URLBookmark] = []
    @Published var errorMessage: String?
    @Published var pendingImports: [ImportJob] = []
    @Published var selectedArticleID: String?
    @Published var undoAvailable = false
    // Keep the container alive for as long as its context and model objects are used.
    private let container: ModelContainer?
    private let context: ModelContext?
    private var undoMark: (String, SourceRef)?
    private var timingStart: Date?
    private var timingKind = "paused"
    private var timingArticle: String?

    init(context: ModelContext?, initializationError: String? = nil) {
        self.container = context?.container
        self.context = context
        self.errorMessage = initializationError
        reload()
    }

    var selectedArticle: StoredArticle? { articles.first { $0.id == selectedArticleID } }
    func reload() {
        guard let context else { return }
        do {
            articles = try context.fetch(FetchDescriptor<StoredArticle>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
            urlBookmarks = try context.fetch(FetchDescriptor<URLBookmark>())
        }
        catch { errorMessage = "保存データを読み込めませんでした。\(error.localizedDescription)" }
    }

    func seedDemoIfNeeded() {
        guard articles.isEmpty, context != nil else { return }
        // Seeding is an explicit first-launch action; deleting all data does not restore it automatically.
        let isUITest = ProcessInfo.processInfo.arguments.contains("--ui-test-memory")
        guard isUITest || !UserDefaults.standard.bool(forKey: "demoSeeded") else { return }
        do {
            try add(title: DemoTutor.sampleTitle, sourceURL: nil, blocks: ArticleImporter.pastedBlocks(DemoTutor.sampleText))
            if !isUITest { UserDefaults.standard.set(true, forKey: "demoSeeded") }
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func add(title: String, sourceURL: URL?, author: String? = nil, blocks: [(BlockKind, String)], extractionVersion: String = "paste-v1", importJobID: UUID? = nil) throws -> StoredArticle {
        guard let context else { throw StoreError.unavailable }
        if let importJobID, try context.fetch(FetchDescriptor<ProcessedImport>()).contains(where: { $0.id == importJobID.uuidString }) {
            throw StoreError.alreadyImported
        }
        let prior = sourceURL.flatMap { url in articles.first { $0.sourceURL == url.absoluteString } }
        let snapshot = try ArticleImporter.snapshot(articleID: prior?.articleID ?? UUID().uuidString, blocks: blocks, extractorVersion: extractionVersion)
        let article = try StoredArticle(snapshot: snapshot, title: title.isEmpty ? "Untitled" : title, sourceURL: sourceURL, author: author)
        context.insert(article)
        if let importJobID { context.insert(ProcessedImport(id: importJobID.uuidString, articleID: article.articleID)) }
        do { try context.save() } catch { context.rollback(); throw error }
        reload()
        selectedArticleID = article.id
        return article
    }

    func activity(_ article: StoredArticle) -> ArticleActivity {
        do { return try article.activity() }
        catch { errorMessage = "学習記録を読み込めませんでした。記録は上書きしません。"; return ArticleActivity() }
    }

    func update(_ article: StoredArticle, _ mutation: (inout ArticleActivity) throws -> Void) throws {
        guard let context else { throw StoreError.unavailable }
        var activity = try article.activity()
        try mutation(&activity)
        let encoded = try JSONEncoder().encode(activity)
        article.activityData = encoded
        do { try context.save() } catch { context.rollback(); throw error }
        objectWillChange.send()
    }

    func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { errorMessage = error.localizedDescription }
    }

    func toggleMark(_ ref: SourceRef, article: StoredArticle, allowUndo: Bool = true) {
        perform {
            _ = try SourceResolver(snapshot: article.snapshot()).resolve(ref)
            try update(article) { activity in
                activity.focusedSource = ref
                if let index = activity.marks.firstIndex(where: { $0.source == ref }) {
                    activity.marks[index].active.toggle()
                } else {
                    activity.marks.append(LocalMark(source: ref, active: true, createdAt: Date()))
                    activity.evidence.append(EvidenceEntry(source: ref, kind: "marked_unchecked", createdAt: Date()))
                }
                activity.stateRevision += 1
                if var run = activity.learningRun, run.order.contains(ref), !run.finished {
                    try LearningReducer(snapshot: article.snapshot()).apply(.selectSource(ref), to: &run)
                    activity.learningRun = run; activity.stateRevision = run.revision
                }
            }
            if allowUndo { undoMark = (article.id, ref); undoAvailable = true }
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    func undoLastMark() {
        guard let undoMark, let article = articles.first(where: { $0.id == undoMark.0 }) else { return }
        toggleMark(undoMark.1, article: article, allowUndo: false)
        self.undoMark = nil
        undoAvailable = false
    }

    func focus(_ ref: SourceRef, article: StoredArticle) {
        perform {
            _ = try SourceResolver(snapshot: article.snapshot()).resolve(ref)
            try update(article) { state in
                state.focusedSource = ref; state.stateRevision += 1
                if var run = state.learningRun, run.order.contains(ref), !run.finished {
                    try LearningReducer(snapshot: article.snapshot()).apply(.selectSource(ref), to: &run)
                    state.learningRun = run; state.stateRevision = run.revision
                }
            }
        }
    }

    func beginReader(_ article: StoredArticle) {
        perform {
            let resolver = try SourceResolver(snapshot: article.snapshot())
            try update(article) { state in
                if state.focusedSource == nil { state.focusedSource = resolver.allSentenceRefs.first }
                if state.readingRuns.last?.completedAt != nil || state.readingRuns.isEmpty {
                    let kind = state.readingRuns.isEmpty ? "firstPass" : "reread"
                    state.readingRuns.append(LocalReadingRun(kind: kind, startedAt: Date()))
                }
            }
        }
        setTiming("read", article: article)
    }

    func savePosition(_ blockID: String, article: StoredArticle) {
        perform { try update(article) { $0.readingPosition = blockID } }
    }

    func setTiming(_ kind: String, article: StoredArticle?) {
        flushTiming()
        timingStart = Date()
        timingKind = kind
        timingArticle = article?.id
    }

    func flushTiming() {
        guard let start = timingStart, let id = timingArticle, let article = articles.first(where: { $0.id == id }) else { timingStart = nil; return }
        let segment = LocalTimingSegment(kind: timingKind, startedAt: start, endedAt: Date())
        perform { try update(article) { state in
            if !state.readingRuns.isEmpty && state.readingRuns[state.readingRuns.count - 1].completedAt == nil {
                state.readingRuns[state.readingRuns.count - 1].segments.append(segment)
            }
        } }
        timingStart = nil
    }

    func completeReading(_ article: StoredArticle) {
        flushTiming()
        perform { try update(article) { state in
            if !state.readingRuns.isEmpty && state.readingRuns[state.readingRuns.count - 1].completedAt == nil {
                let index = state.readingRuns.count - 1
                state.readingRuns[index].completedAt = Date()
                state.readingRuns[index].completedWordCount = try ArticleImporter.wordCount(article.snapshot())
                state.readingRuns[index].hasAssistance = state.readingRuns[index].segments.contains { $0.kind == "tutor" }
                state.readingRuns[index].heardSource = state.readingRuns[index].segments.contains { $0.kind == "listen" }
            }
        } }
        setTiming("paused", article: article)
    }

    func beginLearning(_ article: StoredArticle, review: Bool) {
        perform {
            let resolver = try SourceResolver(snapshot: article.snapshot())
            try update(article) { state in
                let marked = Set(state.marks.filter(\.active).map(\.source))
                let order = resolver.allSentenceRefs.filter { !review || marked.contains($0) || state.deferredSources.contains($0) }
                state.learningOrder = order
                state.reviewMode = review
                if let current = state.focusedSource, order.contains(current) {} else { state.focusedSource = order.first }
                if !order.isEmpty {
                    if state.learningRun?.order != order || state.learningRun?.finished == true || state.learningRun?.mode != (review ? .markedReview : .reading) {
                        if let old = state.learningRun { state.archivedLearningRuns.append(old) }
                        state.learningRun = try LearningRun(mode: review ? .markedReview : .reading, order: order)
                    }
                    if var run = state.learningRun, let current = state.focusedSource {
                        try LearningReducer(snapshot: article.snapshot()).apply(.selectSource(current), to: &run)
                        state.learningRun = run; state.learningRunID = run.id; state.stateRevision = run.revision
                    }
                }
            }
        }
        setTiming("tutor", article: article)
    }

    @discardableResult
    func navigate(_ delta: Int, article: StoredArticle, deferCurrent: Bool = false) -> Bool {
        var moved = false
        perform {
            try update(article) { state in
                if deferCurrent, let current = state.focusedSource {
                    state.deferredSources.insert(current)
                    state.evidence.append(EvidenceEntry(source: current, kind: "deferred", createdAt: Date()))
                }
                guard var run = state.learningRun else { return }
                let reducer = try LearningReducer(snapshot: article.snapshot())
                if deferCurrent { try reducer.apply(.deferCurrent(reason: "user", at: Date()), to: &run) }
                let result = try reducer.apply(delta < 0 ? .previous : .next, to: &run)
                moved = result != .atBoundary
                state.learningRun = run; state.focusedSource = run.currentRef; state.stateRevision = run.revision
            }
        }
        return moved
    }

    func recordExplanation(_ text: String, article: StoredArticle, ref: SourceRef, requestID: String? = nil) throws {
        try update(article) { state in
            state.turns.append(StoredTurn(requestID: requestID, role: "assistant", text: text, source: ref, createdAt: Date()))
            state.evidence.append(EvidenceEntry(source: ref, kind: "explanation_seen", createdAt: Date(), requestID: requestID))
            state.reviewDueAt[ref.sentenceID ?? ref.blockID] = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
            if var run = state.learningRun, run.currentRef == ref {
                try LearningReducer(snapshot: article.snapshot()).apply(.explanationViewed(Date()), to: &run)
                state.learningRun = run; state.stateRevision = run.revision
            }
        }
    }

    func reportUnderstanding(_ article: StoredArticle, ref: SourceRef) {
        perform { try update(article) { state in
            state.evidence.append(EvidenceEntry(source: ref, kind: "self_reported_understood", createdAt: Date()))
            if var run = state.learningRun, run.currentRef == ref {
                try LearningReducer(snapshot: article.snapshot()).apply(.selfReportedUnderstood(Date()), to: &run)
                state.learningRun = run; state.stateRevision = run.revision
            }
        } }
    }

    func deleteArticle(_ article: StoredArticle) {
        guard let context else { return }
        if timingArticle == article.id { flushTiming() }
        perform {
            let jobs = try context.fetch(FetchDescriptor<ProcessedImport>()).filter { $0.articleID == article.articleID }
            // A previous DB commit may have succeeded while inbox acknowledgement failed.
            // Remove those exact inbox jobs before their durable deduplication records.
            if !jobs.isEmpty {
                let inbox = try ImportInbox.shared()
                for job in jobs { if let id = UUID(uuidString: job.id) { try inbox.acknowledge(id) } }
            }
            for record in articles where record.articleID == article.articleID { context.delete(record) }
            for job in jobs { context.delete(job) }
            try context.save()
            if selectedArticleID == article.id { selectedArticleID = nil }
            reload()
        }
    }

    func deleteAll() {
        guard let context else { return }
        flushTiming()
        perform {
            try context.delete(model: StoredArticle.self)
            try context.delete(model: ProcessedImport.self)
            try context.delete(model: URLBookmark.self)
            try context.save()
            try ImportInbox.shared().removeAll()
            selectedArticleID = nil
            pendingImports = []
            reload()
        }
    }

    func refreshInbox() { perform {
        let result = try ImportInbox.shared().loadPending()
        pendingImports = result.jobs
        if result.unreadableFileCount > 0 { errorMessage = "受信トレイに読み込めないファイルがあります。削除せず保持しました。" }
    } }
    func discardImport(_ job: ImportJob) { perform { try ImportInbox.shared().acknowledge(job.id); refreshInbox() } }
    func saveURLOnly(_ job: ImportJob) throws {
        guard let context, let url = job.sourceURL else { throw StoreError.unavailable }
        if !urlBookmarks.contains(where: { $0.importJobID == job.id.uuidString }) {
            context.insert(URLBookmark(title: job.title, url: url.absoluteString, importJobID: job.id.uuidString))
            try context.save()
        }
        try ImportInbox.shared().acknowledge(job.id)
        reload(); refreshInbox()
    }
    func deleteBookmark(_ bookmark: URLBookmark) { perform {
        guard let context else { return }
        context.delete(bookmark); try context.save(); reload()
    } }

    enum StoreError: LocalizedError {
        case unavailable, alreadyImported
        var errorDescription: String? {
            switch self { case .unavailable: "保存領域を開けません。端末の空き容量と保存データを確認してください。"; case .alreadyImported: "この取り込みは保存済みです。受信トレイから削除できます。" }
        }
    }
}

@Model
final class ProcessedImport {
    @Attribute(.unique) var id: String
    var articleID: String
    init(id: String, articleID: String) { self.id = id; self.articleID = articleID }
}

@Model
final class URLBookmark {
    @Attribute(.unique) var id: String
    var title: String
    var url: String
    var importJobID: String
    init(title: String, url: String, importJobID: String) {
        self.id = UUID().uuidString; self.title = title; self.url = url; self.importJobID = importJobID
    }
}
