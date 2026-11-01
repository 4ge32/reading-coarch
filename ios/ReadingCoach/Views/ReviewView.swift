import ReadingCore
import SwiftUI

struct ReviewView: View {
    @EnvironmentObject private var store: ReadingStore
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.articles) { article in
                    if let snapshot = try? article.snapshot() {
                        let state = store.activity(article)
                        let resolver = SourceResolver(snapshot: snapshot)
                        let targets = Set(state.marks.filter(\.active).map(\.source)).union(state.deferredSources)
                        if !targets.isEmpty {
                            Section(article.title) {
                                ForEach(resolver.allSentenceRefs.filter { targets.contains($0) }, id: \.self) { ref in
                                    NavigationLink { ReviewTutorHost(article: article, ref: ref) } label: {
                                        VStack(alignment: .leading) {
                                            Text((try? resolver.resolve(ref).text) ?? "参照エラー")
                                            Text(state.deferredSources.contains(ref) ? "保留中" : reviewLabel(state, ref: ref)).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .overlay { if store.articles.allSatisfy({ store.activity($0).marks.filter(\.active).isEmpty && store.activity($0).deferredSources.isEmpty }) { ContentUnavailableView("復習対象はありません", systemImage: "bookmark", description: Text("Readerで分かりにくい文をタップして記録します。")) } }
            .navigationTitle("復習")
        }
    }
    private func reviewLabel(_ state: ArticleActivity, ref: SourceRef) -> String {
        if let due = state.reviewDueAt[ref.sentenceID ?? ref.blockID] { return due <= Date() ? "再確認の対象" : "\(due.formatted(date: .abbreviated, time: .omitted))以降に再確認" }
        return "未確認"
    }
}

private struct ReviewTutorHost: View {
    @EnvironmentObject private var store: ReadingStore
    let article: StoredArticle
    let ref: SourceRef
    @StateObject private var speech = SourceSpeech()
    var body: some View {
        TutorView(article: article, speech: speech)
            .onAppear { store.focus(ref, article: article); store.beginLearning(article, review: true) }
            .onDisappear { speech.stop(); store.setTiming("paused", article: article) }
    }
}
