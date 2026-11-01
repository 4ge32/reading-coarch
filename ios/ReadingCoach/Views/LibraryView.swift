import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: ReadingStore
    @State private var importing = false
    @State private var shareJob: ImportJob?
    var body: some View {
        NavigationStack {
            List {
                if let recent = store.articles.first(where: { store.activity($0).readingPosition != nil }) {
                    Section("続きから") {
                        NavigationLink(recent.title) { ReaderView(article: recent) }
                    }
                }
                if !store.pendingImports.isEmpty {
                    Section("Safariからの取り込み") {
                        ForEach(store.pendingImports) { job in
                            Button { shareJob = job } label: {
                                VStack(alignment: .leading) { Text(job.title); Text("プレビューして確認").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                Section("記事一覧") {
                    ForEach(store.articles) { article in
                        NavigationLink { ReaderView(article: article) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(article.title)
                                let state = store.activity(article)
                                Text("\(state.marks.filter(\.active).count)件のマーク · \(article.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions { Button("削除", role: .destructive) { store.deleteArticle(article) } }
                    }
                }
                if !store.urlBookmarks.isEmpty {
                    Section("本文未取得") {
                        ForEach(store.urlBookmarks) { bookmark in
                            VStack(alignment: .leading) {
                                Text(bookmark.title)
                                Text("Safariでページを共有し直すか、本文を貼り付けてください。").font(.caption)
                                if let url = URL(string: bookmark.url) { Link("Safariで開く", destination: url) }
                            }
                        }
                        .onDelete { indices in for index in indices { store.deleteBookmark(store.urlBookmarks[index]) } }
                    }
                }
                if store.articles.isEmpty {
                    Button("サンプル記事を追加") { store.perform { try store.add(title: DemoTutor.sampleTitle, sourceURL: nil, blocks: ArticleImporter.pastedBlocks(DemoTutor.sampleText)) } }
                }
            }
            .navigationTitle("ReadingCoach")
            .toolbar { Button { importing = true } label: { Label("取り込み", systemImage: "plus") } }
            .sheet(isPresented: $importing) { ImportPreviewView(job: nil) }
            .sheet(item: $shareJob) { job in ImportPreviewView(job: job) }
        }
    }
}
