import AVFoundation
import ReadingCore
import SwiftUI

struct ReaderView: View {
    @EnvironmentObject private var store: ReadingStore
    @Environment(\.scenePhase) private var scenePhase
    let article: StoredArticle
    @StateObject private var speech = SourceSpeech()
    @State private var tutoring = false
    @State private var showMarks = false
    @State private var completed = false
    @State private var scrollPosition: String?
    @State private var didRestorePosition = false
    private var snapshot: ArticleSnapshot? { try? article.snapshot() }
    private var activity: ArticleActivity { store.activity(article) }

    var body: some View {
        Group {
            if let snapshot {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            Text(article.title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                            if let url = article.sourceURL { Text(url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            Text("文をタップするとマーク。解説は自動で開きません。").font(.caption).foregroundStyle(.secondary)
                            ForEach(snapshot.blocks) { block in
                                blockView(block, snapshot: snapshot).id(block.id)
                            }
                            Button("この記事を読み終えた") { store.completeReading(article); completed = true }
                                .buttonStyle(.bordered).padding(.vertical)
                            Button("任意の抜き取り確認（未マークの文）") {
                                let marked = Set(activity.marks.filter(\.active).map(\.source))
                                if let target = SourceResolver(snapshot: snapshot).allSentenceRefs.first(where: { !marked.contains($0) }) {
                                    store.focus(target, article: article); openTutor(review: false)
                                }
                            }.font(.caption)
                            if completed { Text("完読を保存しました。速度は読書時間の目安で、理解の評価ではありません。").font(.caption) }
                            if completed { Button("新しい再読区間を始める") { store.beginReader(article); completed = false }.font(.caption) }
                            ForEach(activity.readingRuns) { run in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(run.kind == "firstPass" ? "初読の記録" : "再読の記録").font(.headline)
                                    Text("読書時間の目安：\(Int(run.readSeconds))秒").font(.caption)
                                    let tutor = run.segments.filter { $0.kind == "tutor" }.reduce(0) { $0 + $1.duration }
                                    let listen = run.segments.filter { $0.kind == "listen" }.reduce(0) { $0 + $1.duration }
                                    Text("解説・音声学習：\(Int(tutor))秒 · 原文音声：\(Int(listen))秒").font(.caption)
                                    if run.completedAt != nil, let wordCount = run.completedWordCount, run.readSeconds > 0 {
                                        Text("参考WPM：\(Int(Double(wordCount) / run.readSeconds * 60))（\(run.hasAssistance ? "補助あり" : "補助なし")・\(run.heardSource ? "原文音声あり" : "原文音声なし")・画面表示に基づく概算）").font(.caption)
                                    }
                                }
                            }
                        }
                        .padding(22).scrollTargetLayout()
                    }
                    .scrollPosition(id: $scrollPosition)
                    .onAppear {
                        if !didRestorePosition {
                            let initial = activity.readingPosition
                            didRestorePosition = true
                            scrollPosition = initial
                            if let initial { proxy.scrollTo(initial, anchor: .top) }
                        }
                    }
                    .onChange(of: scrollPosition) { _, position in
                        if didRestorePosition, let position { store.savePosition(position, article: article) }
                    }
                    .onChange(of: showMarks) { _, showing in
                        if !showing, let ref = activity.focusedSource { proxy.scrollTo(ref.blockID, anchor: .center) }
                    }
                }
                .safeAreaInset(edge: .bottom) { readerControls(snapshot) }
            } else { ContentUnavailableView("原文を開けません", systemImage: "exclamationmark.triangle", description: Text("保存済みスナップショットが無効です。本文を推測で補うことはありません。")) }
        }
        .navigationTitle("Reader").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.selectedArticleID = article.id
            store.beginReader(article)
            speech.onWillPlay = { store.setTiming("listen", article: article) }
            speech.onFinished = { store.setTiming(tutoring ? "tutor" : "read", article: article) }
            speech.onSourceFinished = { source in store.perform { try store.update(article) { $0.sourceHeard.insert(source) } } }
            speech.onInterrupted = { store.setTiming("paused", article: article) }
        }
        .onDisappear { speech.stop(); store.setTiming("paused", article: article) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { speech.interrupt(); store.setTiming("paused", article: article) }
            else { store.setTiming(tutoring ? "tutor" : "read", article: article) }
        }
        .sheet(isPresented: $tutoring, onDismiss: { speech.stop(); store.setTiming("read", article: article) }) {
            TutorView(article: article, speech: speech)
        }
        .sheet(isPresented: $showMarks) { MarkListView(article: article) }
        .alert("音声", isPresented: Binding(get: { speech.errorMessage != nil }, set: { if !$0 { speech.errorMessage = nil } })) {
            Button("閉じる") { speech.errorMessage = nil }
        } message: { Text(speech.errorMessage ?? "") }
    }

    @ViewBuilder private func blockView(_ block: ArticleBlock, snapshot: ArticleSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if block.sentences.isEmpty { Text(block.text).textSelection(.enabled) }
            ForEach(block.sentences) { sentence in
                let ref = SourceRef(articleID: snapshot.articleID, snapshotID: snapshot.id, blockID: block.id, sentenceID: sentence.id, rangeUTF16: sentence.rangeUTF16)
                let text = (try? SourceResolver(snapshot: snapshot).resolve(ref).text) ?? ""
                let marked = activity.marks.contains { $0.active && $0.source == ref }
                let speaking = speech.playingSource?.sentenceID == sentence.id
                Button { store.toggleMark(ref, article: article) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if block.kind == .listItem { Text("•") }
                        Text(text).frame(maxWidth: .infinity, alignment: .leading)
                        if marked { Image(systemName: "bookmark.fill").font(.caption).accessibilityHidden(true) }
                    }
                    .font(block.kind == .heading ? .title2.bold() : block.kind == .code ? .system(.body, design: .monospaced) : .body)
                    .lineSpacing(6).foregroundStyle(.primary).padding(5)
                    .background(speaking ? Color.blue.opacity(0.22) : marked ? Color.yellow.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(text)
                .accessibilityValue(marked ? "マーク済み" : "未マーク")
                .accessibilityHint("ダブルタップでマークを切り替えます")
                .accessibilityIdentifier("sentence-\(sentence.id)")
                .contextMenu { Button("この文を相談") { store.focus(ref, article: article); openTutor(review: false) }; Button("原文を聞く") { play(ref, snapshot: snapshot) } }
            }
        }
        .padding(.leading, block.kind == .blockquote ? 12 : 0)
    }

    private func readerControls(_ snapshot: ArticleSnapshot) -> some View {
        VStack(spacing: 8) {
            if let ref = activity.focusedSource, let source = try? SourceResolver(snapshot: snapshot).resolve(ref) {
                Text("対象：\(source.text)").font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button { showMarks = true } label: { Label("マーク", systemImage: "bookmark") }
                Spacer()
                Button { if let ref = activity.focusedSource { play(ref, snapshot: snapshot) } } label: { Label("原文", systemImage: "speaker.wave.2") }.disabled(activity.focusedSource == nil)
                Spacer()
                Button("相談") { openTutor(review: false) }.disabled(activity.focusedSource == nil)
                if store.undoAvailable { Button { store.undoLastMark() } label: { Image(systemName: "arrow.uturn.backward") }.accessibilityLabel("マーク操作を取り消す") }
            }
            if speech.playingSource != nil {
                HStack {
                    Button(speech.isPaused ? "再開" : "一時停止") { speech.pauseOrResume() }
                    Button("停止", role: .destructive) { speech.stop() }
                    Picker("速度", selection: $speech.speed) { ForEach(SourceSpeech.Speed.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
                }
                Text("原文読み上げ中。音声での割り込みは保証されません。").font(.caption2)
            }
        }
        .padding().background(.regularMaterial)
    }
    private func play(_ ref: SourceRef, snapshot: ArticleSnapshot) {
        store.perform { try store.update(article) { $0.lastPlayedSource = ref } }
        speech.play([ref], snapshot: snapshot)
    }
    private func openTutor(review: Bool) { speech.stop(); store.beginLearning(article, review: review); tutoring = true }
}

struct MarkListView: View {
    @EnvironmentObject private var store: ReadingStore
    @Environment(\.dismiss) private var dismiss
    let article: StoredArticle
    var body: some View {
        NavigationStack {
            List {
                if let snapshot = try? article.snapshot() {
                    let resolver = SourceResolver(snapshot: snapshot)
                    let marks = Set(store.activity(article).marks.filter(\.active).map(\.source))
                    ForEach(resolver.allSentenceRefs.filter { marks.contains($0) }, id: \.self) { ref in
                        Button((try? resolver.resolve(ref).text) ?? "参照エラー") { store.focus(ref, article: article); dismiss() }
                    }
                }
            }
            .navigationTitle("マークした文")
            .toolbar { Button("閉じる") { dismiss() } }
        }
    }
}
