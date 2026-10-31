import Foundation

public enum ReadingPass: String, Codable, Sendable { case firstPass, reread }
public enum TimingActivity: String, Codable, Sendable { case read, tutor, listen, paused }
public enum TimingError: Error, Equatable { case nonMonotonicTime, invalidWordCount, invalidCompletion }

public struct TimingSegment: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let runID: String
    public let activity: TimingActivity
    public let pass: ReadingPass
    public let start: Date
    public let end: Date
    public let approximate: Bool
    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// Exactly one activity is active at a time. Foreground inactivity alone never stops a reader timer.
public struct ReadingTimer: Codable, Sendable {
    public let runID: String
    public let pass: ReadingPass
    public private(set) var segments: [TimingSegment] = []
    public private(set) var currentActivity: TimingActivity
    public private(set) var startedAt: Date
    public private(set) var hasAssistance = false
    public private(set) var heardSource = false
    public private(set) var completedWordCount: Int?
    public let wordCountVersion: String

    public init(runID: String, pass: ReadingPass, activity: TimingActivity = .read, at: Date = Date()) {
        self.runID = runID; self.pass = pass; currentActivity = activity; startedAt = at
        wordCountVersion = "unicode-letters-apostrophe-hyphen-v1"
        hasAssistance = activity == .tutor; heardSource = activity == .listen
    }
    public mutating func transition(to activity: TimingActivity, at: Date) throws {
        guard completedWordCount == nil else { throw TimingError.invalidCompletion }
        guard at >= startedAt else { throw TimingError.nonMonotonicTime }
        guard activity != currentActivity else { return }
        close(at: at)
        currentActivity = activity; startedAt = at
        if activity == .tutor { hasAssistance = true }
        if activity == .listen { heardSource = true }
    }
    public mutating func finish(wordCount: Int, at: Date) throws {
        guard wordCount > 0 else { throw TimingError.invalidWordCount }
        guard at >= startedAt, completedWordCount == nil else { throw TimingError.invalidCompletion }
        close(at: at); currentActivity = .paused; startedAt = at; completedWordCount = wordCount
    }
    public func duration(for activity: TimingActivity) -> TimeInterval {
        segments.filter { $0.activity == activity }.reduce(0) { $0 + $1.duration }
    }
    public var wordsPerMinute: Double? {
        guard let words = completedWordCount else { return nil }
        let seconds = duration(for: .read)
        guard seconds > 0 else { return nil }
        return Double(words) * 60 / seconds
    }
    private mutating func close(at: Date) {
        guard at > startedAt else { return }
        segments.append(TimingSegment(id: UUID().uuidString, runID: runID, activity: currentActivity,
                                      pass: pass, start: startedAt, end: at, approximate: true))
    }
    /// Letter/number runs count as words; internal apostrophes and hyphens join a word. Code blocks are excluded by callers.
    public static func wordCount(_ text: String) -> Int {
        let pattern = "[\\p{L}\\p{N}]+(?:['’\\-][\\p{L}\\p{N}]+)*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
