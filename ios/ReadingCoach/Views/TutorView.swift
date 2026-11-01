import ReadingCore
import SwiftUI

struct TutorView: View {
    @EnvironmentObject private var store: ReadingStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("connectionMode") private var mode = ConnectionMode.demo.rawValue
    @AppStorage("backendURL") private var backendURL = ""
    @AppStorage("liveConsent") private var liveConsent = false
    let article: StoredArticle
    @ObservedObject var speech: SourceSpeech
    @State private var answer = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var boundaryMessage: String?
    @State private var voice: LiveVoiceSession?
    @State private var pendingTask: Task<Void, Never>?
    @State private var correctingTurn: String?
    @State private var activeRequestID: String?
    @State private var selectedPracticeID: String?
    private var state: ArticleActivity { store.activity(article) }
    private var snapshot: ArticleSnapshot? { try? article.snapshot() }
    private var ref: SourceRef? { state.focusedSource }
    private var isDemo: Bool { mode == ConnectionMode.demo.rawValue }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(isDemo ? "Demo：応答はサンプル" : "Live：限定した本文と回答を外部APIへ送信").font(.caption).foregroundStyle(.secondary)
                    if let snapshot, let ref, let source = try? SourceResolver(snapshot: snapshot).resolve(ref) {
                        Text("保存済み原文").font(.caption.bold())
                        Text(source.text).font(.title3).textSelection(.enabled)
                        HStack {
                            Button("原文を聞く") { playSource(ref) }
                            Button("前後も聞く") { playContext(ref) }
                            Button("もう一回") { if let last = state.lastPlayedSource { playSource(last) } }.disabled(state.lastPlayedSource == nil)
                        }.font(.caption)
                        Picker("原文の速さ", selection: $speech.speed) { ForEach(SourceSpeech.Speed.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                        if speech.playingSource != nil {
                            HStack { Button(speech.isPaused ? "再開" : "一時停止") { speech.pauseOrResume() }; Button("停止", role: .destructive) { speech.stop() } }
                            Text("原文音声中はマイクの送信を一時停止します。停止ボタンを使ってください。").font(.caption)
                        }
                        Divider()
                        ForEach(state.turns.filter { $0.source == ref }) { turn in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(turn.role == "user" ? "あなた\(turn.practiceID != nil ? "（練習文への回答）" : "")\(turn.superseded ? "（訂正前・評価対象外）" : "")" : "AIの解説\(isDemo ? "（サンプル）" : "")").font(.caption.bold())
                                Text(turn.text).textSelection(.enabled).foregroundStyle(turn.superseded ? .secondary : .primary)
                                if turn.role == "user" && !turn.superseded {
                                    Button("回答・転記を訂正") { answer = turn.text; correctingTurn = turn.id; selectedPracticeID = turn.practiceID }.font(.caption)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding().background(turn.role == "user" ? Color.blue.opacity(0.08) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if !state.generatedPractice.filter({ $0.sourceRef == ref }).isEmpty {
                            Text("練習文（AI生成・原文ではありません）").font(.caption.bold())
                            ForEach(state.generatedPractice.filter { $0.sourceRef == ref }) { item in
                                VStack(alignment: .leading) {
                                    Text(item.text).italic()
                                    Button(selectedPracticeID == item.id ? "この練習文に回答中" : "この練習文の意味を確認") { selectedPracticeID = item.id; answer = "" }
                                        .font(.caption)
                                }
                            }
                        }
                        if let selectedPracticeID, let practice = state.generatedPractice.first(where: { $0.id == selectedPracticeID && $0.sourceRef == ref }) {
                            Text("回答対象：練習文（原文ではありません）\n\(practice.text)").font(.caption).foregroundStyle(.purple)
                            Button("原文の相談へ戻る") { self.selectedPracticeID = nil }.font(.caption)
                        }
                        TextField("今の解釈、質問、訂正した回答", text: $answer, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...6)
                        HStack {
                            Button(correctingTurn == nil ? "送る" : "訂正して再送") { send(answer, task: selectedPracticeID == nil ? "tutor" : "assess", practice: state.generatedPractice.first { $0.id == selectedPracticeID && $0.sourceRef == ref }) }.disabled(busy || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("原文を説明して") { send("この文を説明してください。", task: "explain") }.disabled(busy || selectedPracticeID != nil)
                            Button("意味を確認") { send(answer, task: "assess", practice: state.generatedPractice.first { $0.id == selectedPracticeID && $0.sourceRef == ref }) }.disabled(busy || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if busy { HStack { ProgressView(); Button("要求を取り消す") { cancelRequest() } } }
                        if isDemo {
                            Text("Demoは実際の音声会話・意味評価を行いません。原文TTSは端末の音声で動きます。").font(.caption)
                        } else if let voice {
                            LiveVoiceView(session: voice)
                        } else {
                            Button("Live音声を準備") { prepareVoice() }.disabled(!liveConsent)
                            Text("音声と選択した文脈の送信を設定で許可してください。マイクOFFから声だけで再開することはできません。").font(.caption)
                        }
                        HStack {
                            Button("分かった（自己申告）") { store.reportUnderstanding(article, ref: ref) }
                            Button("別例を作る") { createPractice() }.disabled(busy)
                        }.font(.caption)
                        Text("自己申告・解説の閲覧・音読・補助ありの回答・自力の回答・別例の成功は別の記録です。").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("前") { navigate(-1) }
                            Spacer()
                            Button("後で・次") { navigate(1, deferred: true) }
                            Spacer()
                            Button("次") { navigate(1) }
                        }
                        if let boundaryMessage { Text(boundaryMessage).font(.caption) }
                        if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
                        Button("学習を終了", role: .destructive) { finishSession() }
                    } else { ContentUnavailableView("対象文がありません", systemImage: "text.magnifyingglass", description: Text("Readerで対象の文を選んでください。")) }
                }.padding()
            }
            .navigationTitle(state.reviewMode ? "マークの復習" : "この文を相談")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("読書へ戻る") { cancelRequest(); voice?.disconnect(); speech.stop(); dismiss() } }
            .onAppear { configureSpeech() }
            .onDisappear { cancelRequest(); voice?.disconnect(); speech.stop() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { cancelRequest(); voice?.suspend(); speech.interrupt(); store.setTiming("paused", article: article) }
            }
            .onChange(of: state.stateRevision) { _, _ in if !busy { refreshVoiceContext() } }
        }
    }

    private func context(inputModality: String = "text") throws -> LiveTutorContext {
        guard let snapshot, let ref else { throw LiveServiceError.invalidSource }
        let resolver = SourceResolver(snapshot: snapshot)
        let around = try resolver.context(around: ref)
        let focusBlock = snapshot.blocks.first { $0.id == ref.blockID }
        var passages = around
        for sentence in focusBlock?.sentences ?? [] {
            let sentenceRef = SourceRef(articleID: snapshot.articleID, snapshotID: snapshot.id, blockID: ref.blockID, sentenceID: sentence.id, rangeUTF16: sentence.rangeUTF16)
            if !passages.contains(where: { $0.ref == sentenceRef }), passages.count < 12 { passages.append(try resolver.resolve(sentenceRef)) }
        }
        let entries = state.evidence.filter { $0.source == ref && !$0.superseded }
        return LiveTutorContext(title: article.title, focus: ref, passages: passages.map { passage in
            LiveSourcePassage(sourceRef: passage.ref, blockText: snapshot.blocks.first(where: { $0.id == passage.ref.blockID })!.text, text: passage.text)
        }, explanationSeen: entries.contains { $0.kind == "explanation_seen" }, hintSeen: false, inputModality: inputModality, presentation: state.sourceHeard.contains(ref) ? "listening" : "reading", recentTurns: state.turns.filter { $0.source == ref && !$0.superseded }.suffix(8).map { LiveRecentTurn(role: $0.role, text: String($0.text.prefix(2000))) })
    }

    private func client() throws -> LiveTutorClient {
        guard liveConsent, let url = URL(string: backendURL), url.scheme == "https", let token = try KeychainAccessToken.read(), !token.isEmpty else { throw LiveServiceError.invalidConfiguration }
        return LiveTutorClient(baseURL: url, accessToken: token)
    }

    private func send(_ input: String, task: String, modality: InputModality = .text, practice: PracticeItem? = nil) {
        guard !busy, let ref, let snapshot else { return }
        guard practice == nil || practice?.sourceRef == ref else { errorMessage = "練習文の対象が変わりました。元の文から選び直してください。"; return }
        speech.stop()
        voice?.mute()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let requestID = UUID().uuidString
        do {
            let context = try context(inputModality: modality.rawValue)
            var capturedRunID = state.learningRunID
            var capturedRevision = state.stateRevision
            try store.update(article) { current in
                if let correctingTurn, let index = current.turns.firstIndex(where: { $0.id == correctingTurn }) {
                    current.turns[index].superseded = true
                    for i in current.evidence.indices where current.evidence[i].requestID == current.turns[index].requestID { current.evidence[i].superseded = true }
                }
                current.turns.append(StoredTurn(requestID: requestID, role: "user", text: trimmed, source: ref, createdAt: Date(), inputModality: modality.rawValue, practiceID: practice?.id))
                if var run = current.learningRun, task != "explain" {
                    let exposure = ExposureHistory(hintSeen: context.hintSeen, explanationSeen: context.explanationSeen, sourceHeard: context.presentation == "listening")
                    let lastAnswer = run.attempts.last(where: { $0.sourceRef == ref && !$0.superseded })?.createdAt ?? .distantPast
                    let newSupport = current.evidence.contains { $0.source == ref && $0.kind == "explanation_seen" && $0.createdAt > lastAnswer && !$0.superseded }
                    let action: LearningAction
                    if let practice {
                        action = .submitPracticeAnswer(answer: trimmed, practiceID: practice.id, inputModality: modality, exposure: exposure, newSupportProvided: newSupport, requestID: requestID, at: Date())
                    } else if let correctingTurn, let oldTurn = current.turns.first(where: { $0.id == correctingTurn }), let oldAttempt = run.attempts.last(where: { $0.answer == oldTurn.text && !$0.superseded }) {
                        action = .correctTranscript(attemptID: oldAttempt.id, answer: trimmed, requestID: requestID, at: Date())
                    } else {
                        action = .submitAnswer(answer: trimmed, inputModality: modality, presentation: context.presentation == "listening" ? .sourceAudio : .reading, exposure: exposure, newSupportProvided: newSupport, requestID: requestID, at: Date())
                    }
                    let result = try LearningReducer(snapshot: snapshot).apply(action, to: &run)
                    if case .assessmentRequested(let request) = result { capturedRunID = request.runID; capturedRevision = request.stateRevision }
                    current.learningRun = run; current.stateRevision = run.revision
                }
            }
            answer = ""; correctingTurn = nil
            if isDemo {
                let text = practice == nil ? DemoTutor.reply(source: try SourceResolver(snapshot: snapshot).resolve(ref).text) : "Demoでは練習文の意味評価は行いません。原文とは別の文として、主体・対象・論理関係を考えてみてください。Liveで実際の評価を利用できます。"
                try store.update(article) { current in
                    if var run = current.learningRun { try LearningReducer(snapshot: snapshot).apply(.cancelRequest(requestID), to: &run); current.learningRun = run; current.stateRevision = run.revision }
                }
                try store.recordExplanation(text, article: article, ref: ref, requestID: requestID)
                return
            }
            let client = try client()
            busy = true; errorMessage = nil; activeRequestID = requestID
            pendingTask = Task { @MainActor in
                defer { if activeRequestID == requestID { busy = false; pendingTask = nil; activeRequestID = nil; refreshVoiceContext() } }
                do {
                    let practiceContext = practice.map { LivePracticeContext(id: $0.id, text: $0.text) }
                    let reply = try await client.sendTurn(requestID: requestID, runID: capturedRunID, stateRevision: capturedRevision, context: context, learnerTurn: trimmed, task: task, practice: practiceContext)
                    try Task.checkCancellation()
                    let current = state
                    guard current.learningRunID == reply.runID, current.stateRevision == reply.stateRevision, current.focusedSource == ref else { throw LiveServiceError.staleResponse }
                    for sourceRef in reply.sourceRefs { _ = try SourceResolver(snapshot: snapshot).resolve(sourceRef) }
                    try accept(reply, for: ref, snapshot: snapshot)
                } catch is CancellationError {} catch { if activeRequestID == requestID { errorMessage = error.localizedDescription } }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func accept(_ reply: LiveTutorReply, for ref: SourceRef, snapshot: ArticleSnapshot) throws {
        try store.update(article) { current in
            guard !current.processedRequestIDs.contains(reply.requestID) else { return }
            current.processedRequestIDs.insert(reply.requestID)
            current.turns.append(StoredTurn(requestID: reply.requestID, role: "assistant", text: reply.feedbackJa + (reply.nextPromptJa.map { "\n" + $0 } ?? ""), source: ref, createdAt: Date()))
            if let assessment = reply.assessment, let outcome = AssessmentOutcome(rawValue: assessment.outcome), var run = current.learningRun {
                let mapped = ReadingCore.Assessment(outcome: outcome, matchedPoints: assessment.matchedPoints, missedPoints: assessment.missedPoints, bottleneck: Bottleneck(rawValue: assessment.bottleneck) ?? .unknown)
                let response = AssessmentResponse(requestID: reply.requestID, runID: reply.runID, stateRevision: reply.stateRevision, sourceRef: ref, assessment: mapped)
                let result = try LearningReducer(snapshot: snapshot).apply(.receiveAssessment(response), to: &run)
                guard result != .ignoredStale else { throw LiveServiceError.staleResponse }
                current.learningRun = run; current.stateRevision = run.revision
                let kind = outcome == .meaningMatched ? (run.attempts.last?.practiceID != nil ? "transfer_item_correct" : run.attempts.last?.newSupportProvided == true ? "same_item_correct_supported" : "same_item_correct_without_new_hint") : outcome.rawValue
                current.evidence.append(EvidenceEntry(source: ref, kind: kind, createdAt: Date(), requestID: reply.requestID))
            } else if var run = current.learningRun {
                try LearningReducer(snapshot: snapshot).apply(.cancelRequest(reply.requestID), to: &run)
                current.learningRun = run; current.stateRevision = run.revision
            }
            if reply.intent == "explain" {
                current.evidence.append(EvidenceEntry(source: ref, kind: "explanation_seen", createdAt: Date(), requestID: reply.requestID))
                current.reviewDueAt[ref.sentenceID ?? ref.blockID] = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
                if var run = current.learningRun { try LearningReducer(snapshot: snapshot).apply(.explanationViewed(Date()), to: &run); current.learningRun = run; current.stateRevision = run.revision }
            }
            if let practice = reply.generatedPractice { current.generatedPractice.append(try PracticeItem(id: practice.id ?? "practice:" + UUID().uuidString, text: practice.text, sourceRef: ref, reason: "tutor_generated")) }
        }
    }

    private func cancelRequest() {
        activeRequestID = nil; pendingTask?.cancel(); pendingTask = nil; busy = false
        if let snapshot { store.perform { try store.update(article) { current in
            guard var run = current.learningRun else { return }
            try LearningReducer(snapshot: snapshot).apply(.suspend, to: &run)
            try LearningReducer(snapshot: snapshot).apply(.resume, to: &run)
            current.learningRun = run; current.stateRevision = run.revision
        } } }
    }

    private func configureSpeech() {
        speech.onWillPlay = { voice?.suspendForSource(); store.setTiming("listen", article: article) }
        speech.onFinished = { voice?.resumeAfterSource(); store.setTiming("tutor", article: article) }
        speech.onSourceFinished = { source in store.perform { try store.update(article) { $0.sourceHeard.insert(source) } } }
        speech.onInterrupted = { voice?.suspend(); store.setTiming("paused", article: article) }
    }
    private func playSource(_ target: SourceRef) {
        guard let snapshot else { return }
        store.perform { try store.update(article) { current in
            if var run = current.learningRun { try LearningReducer(snapshot: snapshot).apply(.playSource(target), to: &run); current.learningRun = run; current.stateRevision = run.revision }
            current.lastPlayedSource = target
        } }
        speech.play([target], snapshot: snapshot)
    }
    private func playContext(_ target: SourceRef) {
        guard let snapshot else { return }
        do { speech.play(try SourceResolver(snapshot: snapshot).context(around: target).map(\.ref), snapshot: snapshot) }
        catch { errorMessage = error.localizedDescription }
    }
    private func navigate(_ delta: Int, deferred: Bool = false) {
        cancelRequest(); voice?.disconnect(); voice = nil; speech.stop()
        selectedPracticeID = nil; correctingTurn = nil; answer = ""
        if !store.navigate(delta, article: article, deferCurrent: deferred) { boundaryMessage = "この方向には次の項目がありません。読書へ戻るか、明示的に学習を終了できます。" }
        else { boundaryMessage = nil }
    }
    private func createPractice() {
        if isDemo, let ref { store.perform { try store.update(article) { $0.generatedPractice.append(try PracticeItem(text: "A checklist can be complete without proving that every risk has been considered.", sourceRef: ref, reason: "demo_fixture")) } } }
        else {
            guard !busy else { return }
            do {
                let context = try context()
                let client = try client()
                let runID = state.learningRunID; let revision = state.stateRevision
                let requestID = UUID().uuidString
                busy = true; activeRequestID = requestID
                pendingTask = Task { @MainActor in
                    defer { if activeRequestID == requestID { busy = false; pendingTask = nil; activeRequestID = nil; refreshVoiceContext() } }
                    do {
                        let reply = try await client.createPractice(requestID: requestID, runID: runID, stateRevision: revision, context: context, bottleneck: "unknown")
                        try Task.checkCancellation()
                        guard state.learningRunID == reply.runID, state.stateRevision == reply.stateRevision else { throw LiveServiceError.staleResponse }
                        guard let ref else { throw LiveServiceError.invalidSource }
                        try store.update(article) { $0.generatedPractice.append(try PracticeItem(id: reply.generatedPractice.id ?? "practice:" + UUID().uuidString, text: reply.generatedPractice.text, sourceRef: ref, reason: "generated_for_transfer")) }
                    } catch is CancellationError {} catch { if activeRequestID == requestID { errorMessage = error.localizedDescription } }
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private func finishSession() {
        cancelRequest(); voice?.disconnect(); speech.stop()
        if let snapshot { store.perform { try store.update(article) { current in
            guard var run = current.learningRun else { return }
            try LearningReducer(snapshot: snapshot).apply(.finish(explicitUserIntent: true), to: &run)
            current.learningRun = run; current.stateRevision = run.revision
        } } }
        dismiss()
    }

    private func prepareVoice() {
        do {
            let session = LiveVoiceSession(client: try client(), runID: state.learningRunID, stateRevision: state.stateRevision, context: try context(inputModality: "voice"))
            session.onPlaySource = { target in playSource(target) }
            session.onTranscript = { transcript in answer = transcript }
            session.onConfirmedAnswer = { transcript in
                guard let ref else { return }
                store.perform { try store.update(article) { $0.turns.append(StoredTurn(role: "user", text: transcript, source: ref, createdAt: Date(), inputModality: "voice")) } }
            }
            session.onTurnCompleted = { text in
                guard let ref else { return }
                store.perform { try store.recordExplanation(text, article: article, ref: ref) }
                refreshVoiceContext()
            }
            session.onTranscriptCorrection = { original, corrected in
                guard let turn = state.turns.last(where: { $0.role == "user" && $0.inputModality == "voice" && $0.text == original && !$0.superseded }) else { return }
                correctingTurn = turn.id; answer = corrected
                store.perform { try store.update(article) { current in
                    if let index = current.turns.firstIndex(where: { $0.id == turn.id }) { current.turns[index].superseded = true }
                    if var run = current.learningRun, let snapshot, let attempt = run.activeAttempts.last(where: { $0.answer == original }) {
                        _ = try LearningReducer(snapshot: snapshot).apply(.correctTranscript(attemptID: attempt.id, answer: corrected, requestID: UUID().uuidString, at: Date()), to: &run)
                        current.learningRun = run; current.stateRevision = run.revision
                    }
                } }
                refreshVoiceContext()
            }
            session.onToolCall = { name, arguments in await executeTool(name, arguments: arguments) }
            voice = session
        } catch { errorMessage = error.localizedDescription }
    }

    private func executeTool(_ name: String, arguments: [String: Any]) async -> [String: Any] {
        do {
            guard let snapshot, let ref else { throw LiveServiceError.invalidSource }
            let callID = arguments["toolCallID"] as? String ?? ""
            guard !callID.isEmpty,
                  arguments["runID"] as? String == state.learningRunID,
                  arguments["stateRevision"] as? Int == state.stateRevision else { throw LiveServiceError.staleResponse }
            if state.processedToolIDs.contains(callID) { return ["status": "duplicate"] }
            if let rawRef = arguments["sourceRef"] as? [String: Any] {
                let target = try JSONDecoder().decode(SourceRef.self, from: JSONSerialization.data(withJSONObject: rawRef))
                _ = try SourceResolver(snapshot: snapshot).resolve(target)
                guard target == ref else { throw LiveServiceError.invalidSource }
            }
            try store.update(article) { $0.processedToolIDs.insert(callID) }
            switch name {
            case "get_source_context":
                // Never expands beyond the user-approved initial context.
                let passages = try context().passages
                return ["status": "ok", "passages": try JSONSerialization.jsonObject(with: JSONEncoder().encode(passages))]
            case "play_source": playSource(ref)
            case "navigate":
                let direction = arguments["direction"] as? String ?? ""
                if direction == "return_to_reader" { dismiss() }
                else if direction == "next" { navigate(1) }
                else if direction == "previous" { navigate(-1) }
                else { throw LiveServiceError.malformedResponse }
            case "mark_unclear":
                if !state.marks.contains(where: { $0.active && $0.source == ref }) { store.toggleMark(ref, article: article) }
            case "set_wait_mode":
                if arguments["enabled"] as? Bool == true { voice?.enterHold() } else { voice?.releaseHold() }
            case "request_assessment":
                guard let confirmed = arguments["answer"] as? String, confirmed == voice?.confirmedAnswer, !confirmed.isEmpty else { throw LiveServiceError.malformedResponse }
                return try await assessVoice(confirmed)
            case "create_practice":
                let runID = state.learningRunID
                let revision = state.stateRevision
                let reply = try await client().createPractice(runID: runID, stateRevision: revision, context: context(inputModality: "voice"), bottleneck: "unknown")
                guard state.learningRunID == reply.runID, state.stateRevision == reply.stateRevision,
                      state.focusedSource == ref else { throw LiveServiceError.staleResponse }
                let practice = try PracticeItem(id: reply.generatedPractice.id ?? "practice:" + UUID().uuidString, text: reply.generatedPractice.text, sourceRef: ref, reason: "voice_generated_for_transfer")
                try store.update(article) { $0.generatedPractice.append(practice) }
                return ["status": "ok", "id": practice.id, "text": practice.text, "label": practice.label, "stateRevision": state.stateRevision]
            case "finish_session":
                guard arguments["explicitUserIntent"] as? Bool == true else { throw LiveServiceError.malformedResponse }
                // Tool assertions are insufficient evidence of user intent; require the visible button.
                return ["status": "confirmation_required", "message": "画面の学習終了ボタンで終了を確認してください。"]
            default: throw LiveServiceError.malformedResponse
            }
            return ["status": "ok", "stateRevision": state.stateRevision]
        } catch { return ["status": "rejected", "message": error.localizedDescription] }
    }

    private func refreshVoiceContext() {
        do { voice?.updateContext(runID: state.learningRunID, stateRevision: state.stateRevision, context: try context(inputModality: "voice")) }
        catch { errorMessage = error.localizedDescription; voice?.disconnect() }
    }

    private func assessVoice(_ confirmed: String) async throws -> [String: Any] {
        guard let snapshot, let ref else { throw LiveServiceError.invalidSource }
        let context = try context(inputModality: "voice")
        let requestID = UUID().uuidString
        var request: AssessmentRequest?
        try store.update(article) { current in
            guard var run = current.learningRun else { throw LiveServiceError.staleResponse }
            let exposure = ExposureHistory(hintSeen: context.hintSeen, explanationSeen: context.explanationSeen, sourceHeard: context.presentation == "listening")
            let lastAnswer = run.attempts.last(where: { $0.sourceRef == ref && !$0.superseded })?.createdAt ?? .distantPast
            let newSupport = current.evidence.contains { $0.source == ref && $0.kind == "explanation_seen" && $0.createdAt > lastAnswer && !$0.superseded }
            let result = try LearningReducer(snapshot: snapshot).apply(.submitAnswer(answer: confirmed, inputModality: .voice, presentation: context.presentation == "listening" ? .sourceAudio : .reading, exposure: exposure, newSupportProvided: newSupport, requestID: requestID, at: Date()), to: &run)
            if case .assessmentRequested(let value) = result { request = value }
            current.learningRun = run; current.stateRevision = run.revision
        }
        guard let request else { throw LiveServiceError.staleResponse }
        let reply = try await client().sendTurn(requestID: requestID, runID: request.runID, stateRevision: request.stateRevision, context: context, learnerTurn: confirmed, task: "assess")
        guard state.stateRevision == reply.stateRevision, state.focusedSource == ref else { throw LiveServiceError.staleResponse }
        try accept(reply, for: ref, snapshot: snapshot)
        refreshVoiceContext()
        return ["status": "ok", "feedbackJa": reply.feedbackJa, "stateRevision": state.stateRevision]
    }
}
