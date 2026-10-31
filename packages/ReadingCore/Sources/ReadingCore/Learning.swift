import Foundation

public enum LearningError: Error, Equatable {
    case invalidRun, invalidAnswer, unknownAttempt, finishedRun, explicitFinishRequired, invalidRequest
}
public enum LearningMode: String, Codable, Sendable { case reading, markedReview }
public enum InputModality: String, Codable, Sendable { case text, voice }
public enum MaterialPresentation: String, Codable, Sendable { case reading, sourceAudio, generatedPractice }
public enum AssessmentOutcome: String, Codable, Sendable {
    case meaningMatched, partiallyMatched, meaningMismatch, uncertain
}
public enum Bottleneck: String, Codable, Sendable { case vocabulary, syntax, reference, logicalRelation, context, unknown }
public struct Assessment: Codable, Hashable, Sendable {
    public let outcome: AssessmentOutcome
    public let matchedPoints: [String]
    public let missedPoints: [String]
    public let bottleneck: Bottleneck
    public init(outcome: AssessmentOutcome, matchedPoints: [String] = [], missedPoints: [String] = [],
                bottleneck: Bottleneck = .unknown) {
        self.outcome = outcome; self.matchedPoints = matchedPoints
        self.missedPoints = missedPoints; self.bottleneck = bottleneck
    }
}
public struct ExposureHistory: Codable, Hashable, Sendable {
    public var hintSeen: Bool
    public var explanationSeen: Bool
    public var sourceHeard: Bool
    public init(hintSeen: Bool = false, explanationSeen: Bool = false, sourceHeard: Bool = false) {
        self.hintSeen = hintSeen; self.explanationSeen = explanationSeen; self.sourceHeard = sourceHeard
    }
}
public enum EvidenceKind: String, Codable, Sendable {
    case markedUnchecked, explanationSeen, selfReportedUnderstood, spokenRepetition
    case sameItemCorrectSupported, sameItemCorrectWithoutNewHint, transferItemCorrect
    case deferred, assessmentUncertain, meaningMismatch, partiallyMatched
}
public struct LearningEvidence: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let sourceRef: SourceRef
    public let kind: EvidenceKind
    public let attemptID: String?
    public let at: Date
    public let exposure: ExposureHistory
    public let detail: String?
    public internal(set) var superseded: Bool
    public init(id: String = UUID().uuidString, sourceRef: SourceRef, kind: EvidenceKind,
                attemptID: String? = nil, at: Date = Date(), exposure: ExposureHistory = .init(),
                detail: String? = nil, superseded: Bool = false) {
        self.id = id; self.sourceRef = sourceRef; self.kind = kind; self.attemptID = attemptID
        self.at = at; self.exposure = exposure; self.detail = detail; self.superseded = superseded
    }
}
public struct LearningAttempt: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let sourceRef: SourceRef
    public let answer: String
    public let inputModality: InputModality
    public let presentation: MaterialPresentation
    public let exposure: ExposureHistory
    public let newSupportProvided: Bool
    public let practiceID: String?
    public let createdAt: Date
    public internal(set) var assessment: Assessment?
    public internal(set) var superseded: Bool
    public init(id: String = UUID().uuidString, sourceRef: SourceRef, answer: String,
                inputModality: InputModality, presentation: MaterialPresentation,
                exposure: ExposureHistory = .init(), newSupportProvided: Bool? = nil,
                practiceID: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.sourceRef = sourceRef; self.answer = answer
        self.inputModality = inputModality; self.presentation = presentation; self.exposure = exposure
        self.newSupportProvided = newSupportProvided ?? (exposure.hintSeen || exposure.explanationSeen)
        self.practiceID = practiceID; self.createdAt = createdAt; assessment = nil; superseded = false
    }
}
public struct AssessmentRequest: Codable, Hashable, Sendable {
    public let requestID: String
    public let runID: String
    public let stateRevision: Int
    public let attempt: LearningAttempt
}
public struct AssessmentResponse: Codable, Hashable, Sendable {
    public let requestID: String
    public let runID: String
    public let stateRevision: Int
    public let sourceRef: SourceRef
    public let assessment: Assessment
    public init(requestID: String, runID: String, stateRevision: Int, sourceRef: SourceRef, assessment: Assessment) {
        self.requestID = requestID; self.runID = runID; self.stateRevision = stateRevision
        self.sourceRef = sourceRef; self.assessment = assessment
    }
}
public struct LearningRun: Codable, Sendable, Identifiable {
    public let id: String
    public let mode: LearningMode
    public let order: [SourceRef]
    public internal(set) var currentIndex: Int
    public internal(set) var revision: Int
    public internal(set) var lastPlayedRef: SourceRef?
    public internal(set) var attempts: [LearningAttempt]
    public internal(set) var evidence: [LearningEvidence]
    public internal(set) var finished: Bool
    public internal(set) var suspended: Bool
    public internal(set) var processedRequestIDs: Set<String>
    public internal(set) var processedToolCallIDs: Set<String>
    var pendingRequests: [String: AssessmentRequest]
    public var currentRef: SourceRef { order[currentIndex] }
    public var activeEvidence: [LearningEvidence] { evidence.filter { !$0.superseded } }
    public var activeAttempts: [LearningAttempt] { attempts.filter { !$0.superseded } }
    public init(id: String = UUID().uuidString, mode: LearningMode = .reading, order: [SourceRef]) throws {
        guard !id.isEmpty, let first = order.first, Set(order).count == order.count,
              order.allSatisfy({ $0.articleID == first.articleID && $0.snapshotID == first.snapshotID })
        else { throw LearningError.invalidRun }
        self.id = id; self.mode = mode; self.order = order; currentIndex = 0; revision = 0
        lastPlayedRef = nil; attempts = []; evidence = []; finished = false; suspended = false
        processedRequestIDs = []; processedToolCallIDs = []; pendingRequests = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case id, mode, order, currentIndex, revision, lastPlayedRef, attempts, evidence, finished, suspended
        case processedRequestIDs, processedToolCallIDs, pendingRequests
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        mode = try c.decode(LearningMode.self, forKey: .mode)
        order = try c.decode([SourceRef].self, forKey: .order)
        currentIndex = try c.decode(Int.self, forKey: .currentIndex)
        revision = try c.decode(Int.self, forKey: .revision)
        lastPlayedRef = try c.decodeIfPresent(SourceRef.self, forKey: .lastPlayedRef)
        attempts = try c.decode([LearningAttempt].self, forKey: .attempts)
        evidence = try c.decode([LearningEvidence].self, forKey: .evidence)
        finished = try c.decode(Bool.self, forKey: .finished)
        suspended = try c.decode(Bool.self, forKey: .suspended)
        processedRequestIDs = try c.decode(Set<String>.self, forKey: .processedRequestIDs)
        processedToolCallIDs = try c.decode(Set<String>.self, forKey: .processedToolCallIDs)
        pendingRequests = try c.decode([String: AssessmentRequest].self, forKey: .pendingRequests)
        guard !id.isEmpty, let first = order.first, order.indices.contains(currentIndex), revision >= 0,
              revision < Int.max, Set(order).count == order.count,
              order.allSatisfy({ $0.articleID == first.articleID && $0.snapshotID == first.snapshotID }),
              Set(attempts.map(\.id)).count == attempts.count,
              attempts.allSatisfy({ order.contains($0.sourceRef) }),
              evidence.allSatisfy({ order.contains($0.sourceRef) }),
              pendingRequests.allSatisfy({ key, request in
                  key == request.requestID && request.runID == id && request.stateRevision <= revision
                    && request.stateRevision >= 0 && attempts.contains(where: { $0 == request.attempt && !$0.superseded })
              }) else { throw LearningError.invalidRun }
    }
}
public enum LearningAction: Sendable {
    case next, previous
    case selectSource(SourceRef)
    case deferCurrent(reason: String, at: Date)
    case playSource(SourceRef)
    case explanationViewed(Date), selfReportedUnderstood(Date), spokenRepetition(Date)
    case submitAnswer(answer: String, inputModality: InputModality, presentation: MaterialPresentation,
                      exposure: ExposureHistory, newSupportProvided: Bool? = nil, requestID: String, at: Date)
    case submitPracticeAnswer(answer: String, practiceID: String, inputModality: InputModality,
                              exposure: ExposureHistory, newSupportProvided: Bool? = nil, requestID: String, at: Date)
    case receiveAssessment(AssessmentResponse)
    case correctTranscript(attemptID: String, answer: String, requestID: String, at: Date)
    case cancelRequest(String)
    case finish(explicitUserIntent: Bool)
    case suspend, resume
}
public enum LearningResult: Equatable, Sendable {
    case changed, atBoundary, duplicate, ignoredStale, finished
    case assessmentRequested(AssessmentRequest)
    case sourcePlayback(ResolvedSource)
}

/// The model supplies suggestions and assessments; only this reducer owns learning state.
public struct LearningReducer: Sendable {
    public let resolver: SourceResolver
    public init(snapshot: ArticleSnapshot) { resolver = SourceResolver(snapshot: snapshot) }

    @discardableResult
    public func apply(_ action: LearningAction, to run: inout LearningRun) throws -> LearningResult {
        guard !run.order.isEmpty, run.order.indices.contains(run.currentIndex), run.revision >= 0,
              run.revision < Int.max else { throw LearningError.invalidRun }
        _ = try resolver.resolve(run.currentRef)
        if case .receiveAssessment(let response) = action { return try receive(response, run: &run) }
        guard !run.finished else { throw LearningError.finishedRun }
        switch action {
        case .selectSource(let ref):
            _ = try resolver.resolve(ref)
            guard let index = run.order.firstIndex(of: ref) else { throw LearningError.invalidRun }
            run.currentIndex = index; run.revision += 1
        case .next:
            guard run.currentIndex + 1 < run.order.count else { return .atBoundary }
            _ = try resolver.resolve(run.order[run.currentIndex + 1])
            run.currentIndex += 1; run.revision += 1
        case .previous:
            guard run.currentIndex > 0 else { return .atBoundary }
            _ = try resolver.resolve(run.order[run.currentIndex - 1])
            run.currentIndex -= 1; run.revision += 1
        case .deferCurrent(let reason, let at):
            run.evidence.append(.init(sourceRef: run.currentRef, kind: .deferred, at: at, detail: reason))
            run.revision += 1
        case .playSource(let ref):
            let source = try resolver.resolve(ref)
            run.lastPlayedRef = ref; run.revision += 1
            return .sourcePlayback(source)
        case .explanationViewed(let at):
            add(.explanationSeen, at: at, run: &run); run.revision += 1
        case .selfReportedUnderstood(let at):
            add(.selfReportedUnderstood, at: at, run: &run); run.revision += 1
        case .spokenRepetition(let at):
            add(.spokenRepetition, at: at, run: &run); run.revision += 1
        case let .submitAnswer(answer, modality, presentation, exposure, newSupport, requestID, at):
            guard presentation != .generatedPractice else { throw LearningError.invalidRequest }
            return try submit(answer, modality: modality, presentation: presentation, exposure: exposure,
                              newSupportProvided: newSupport,
                              practiceID: nil, requestID: requestID, at: at, run: &run)
        case let .submitPracticeAnswer(answer, practiceID, modality, exposure, newSupport, requestID, at):
            guard practiceID.hasPrefix("practice:"), practiceID.count > "practice:".count else { throw LearningError.invalidRequest }
            return try submit(answer, modality: modality, presentation: .generatedPractice, exposure: exposure,
                              newSupportProvided: newSupport,
                              practiceID: practiceID, requestID: requestID, at: at, run: &run)
        case let .correctTranscript(attemptID, answer, requestID, at):
            guard !run.suspended else { throw LearningError.invalidRun }
            guard let index = run.attempts.firstIndex(where: { $0.id == attemptID && !$0.superseded })
            else { throw LearningError.unknownAttempt }
            let old = run.attempts[index]
            guard old.sourceRef == run.currentRef, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !requestID.isEmpty else { throw LearningError.invalidAnswer }
            if run.pendingRequests[requestID] != nil || run.processedRequestIDs.contains(requestID) { return .duplicate }
            run.attempts[index].superseded = true
            for i in run.evidence.indices where run.evidence[i].attemptID == attemptID { run.evidence[i].superseded = true }
            run.pendingRequests = run.pendingRequests.filter { $0.value.attempt.id != attemptID }
            return try submit(answer, modality: old.inputModality, presentation: old.presentation, exposure: old.exposure,
                              newSupportProvided: old.newSupportProvided,
                              practiceID: old.practiceID, requestID: requestID, at: at, run: &run)
        case .cancelRequest(let requestID):
            guard run.pendingRequests.removeValue(forKey: requestID) != nil else { return .ignoredStale }
            run.processedRequestIDs.insert(requestID); run.revision += 1
        case .finish(let explicitUserIntent):
            guard explicitUserIntent else { throw LearningError.explicitFinishRequired }
            run.finished = true; run.revision += 1; run.pendingRequests.removeAll(); return .finished
        case .suspend:
            run.suspended = true; run.revision += 1; run.pendingRequests.removeAll()
        case .resume:
            run.suspended = false; run.revision += 1
        case .receiveAssessment: fatalError("Handled before switch")
        }
        return .changed
    }

    /// Reject stale and foreign tool events before executing an effect. Accepted IDs survive persistence.
    @discardableResult
    public func applyTool(toolCallID: String, runID: String, stateRevision: Int,
                          action: LearningAction, to run: inout LearningRun) throws -> LearningResult {
        guard !toolCallID.isEmpty else { throw LearningError.invalidRequest }
        if run.processedToolCallIDs.contains(toolCallID) { return .duplicate }
        guard runID == run.id, stateRevision == run.revision else { return .ignoredStale }
        let result = try apply(action, to: &run)
        run.processedToolCallIDs.insert(toolCallID)
        return result
    }

    private func add(_ kind: EvidenceKind, at: Date, run: inout LearningRun) {
        run.evidence.append(.init(sourceRef: run.currentRef, kind: kind, at: at))
    }
    private func submit(_ answer: String, modality: InputModality, presentation: MaterialPresentation,
                        exposure: ExposureHistory, newSupportProvided: Bool? = nil,
                        practiceID: String?, requestID: String, at: Date,
                        run: inout LearningRun) throws -> LearningResult {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !requestID.isEmpty else { throw LearningError.invalidAnswer }
        if run.pendingRequests[requestID] != nil || run.processedRequestIDs.contains(requestID) { return .duplicate }
        guard !run.suspended else { throw LearningError.invalidRun }
        var retainedExposure = exposure
        // Prior exposure remains visible even if the current answer used no new hint.
        if run.activeEvidence.contains(where: { $0.sourceRef == run.currentRef && $0.kind == .explanationSeen }) {
            retainedExposure.explanationSeen = true
        }
        let attempt = LearningAttempt(sourceRef: run.currentRef, answer: answer, inputModality: modality,
                                      presentation: presentation, exposure: retainedExposure,
                                      newSupportProvided: newSupportProvided ?? (exposure.hintSeen || exposure.explanationSeen),
                                      practiceID: practiceID, createdAt: at)
        run.attempts.append(attempt); run.revision += 1
        let request = AssessmentRequest(requestID: requestID, runID: run.id, stateRevision: run.revision, attempt: attempt)
        run.pendingRequests[requestID] = request
        return .assessmentRequested(request)
    }
    private func receive(_ response: AssessmentResponse, run: inout LearningRun) throws -> LearningResult {
        if run.processedRequestIDs.contains(response.requestID) { return .duplicate }
        guard !run.finished, !run.suspended, response.runID == run.id, response.stateRevision == run.revision,
              let pending = run.pendingRequests[response.requestID], pending.stateRevision == response.stateRevision,
              pending.attempt.sourceRef == response.sourceRef, response.sourceRef == run.currentRef,
              let index = run.attempts.firstIndex(where: { $0.id == pending.attempt.id && !$0.superseded })
        else { return .ignoredStale }
        _ = try resolver.resolve(response.sourceRef)
        run.attempts[index].assessment = response.assessment
        let attempt = run.attempts[index]
        let kind: EvidenceKind
        switch response.assessment.outcome {
        case .meaningMatched:
            kind = attempt.practiceID != nil ? .transferItemCorrect
                : attempt.newSupportProvided ? .sameItemCorrectSupported : .sameItemCorrectWithoutNewHint
        case .uncertain: kind = .assessmentUncertain
        case .meaningMismatch: kind = .meaningMismatch
        case .partiallyMatched: kind = .partiallyMatched
        }
        run.evidence.append(.init(sourceRef: response.sourceRef, kind: kind, attemptID: attempt.id,
                                  at: attempt.createdAt, exposure: attempt.exposure))
        run.pendingRequests.removeValue(forKey: response.requestID)
        run.processedRequestIDs.insert(response.requestID); run.revision += 1
        return .changed
    }
}

public struct PracticeItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let label: String
    public let sourceRef: SourceRef
    public let reason: String
    public init(id: String = "practice:" + UUID().uuidString, text: String, sourceRef: SourceRef, reason: String) throws {
        guard id.hasPrefix("practice:"), !text.isEmpty else { throw LearningError.invalidRequest }
        self.id = id; self.text = text; label = "generated_practice"; self.sourceRef = sourceRef; self.reason = reason
    }
}

public struct ReviewItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let sourceRef: SourceRef
    public let dueAt: Date
    public let deferredReason: String?
    public let lastAttemptID: String?
    public init(id: String = UUID().uuidString, sourceRef: SourceRef, dueAt: Date,
                deferredReason: String? = nil, lastAttemptID: String? = nil) {
        self.id = id; self.sourceRef = sourceRef; self.dueAt = dueAt
        self.deferredReason = deferredReason; self.lastAttemptID = lastAttemptID
    }
}
