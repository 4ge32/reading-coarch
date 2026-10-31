import SwiftUI

enum ConnectionMode: String, CaseIterable { case demo = "Demo", live = "Live" }

struct RootView: View {
    @EnvironmentObject private var store: ReadingStore
    @AppStorage("connectionMode") private var mode = ConnectionMode.demo.rawValue
    var body: some View {
        VStack(spacing: 0) {
            Text(mode == ConnectionMode.demo.rawValue ? "Demo：応答はサンプル" : "Live：記事の一部と音声を外部APIへ送信")
                .font(.caption).frame(maxWidth: .infinity).padding(7)
                .background(mode == ConnectionMode.demo.rawValue ? Color.orange.opacity(0.16) : Color.blue.opacity(0.16))
            TabView {
                LibraryView().tabItem { Label("ライブラリ", systemImage: "books.vertical") }
                ReviewView().tabItem { Label("復習", systemImage: "arrow.counterclockwise") }
                SettingsView().tabItem { Label("設定", systemImage: "gear") }
            }
        }
        .alert("確認", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("閉じる") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}
