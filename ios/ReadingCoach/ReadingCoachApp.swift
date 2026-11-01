import SwiftData
import SwiftUI

@main
struct ReadingCoachApp: App {
    @StateObject private var store: ReadingStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: ProcessInfo.processInfo.arguments.contains("--ui-test-memory"))
            let container = try ModelContainer(for: StoredArticle.self, ProcessedImport.self, URLBookmark.self, configurations: configuration)
            _store = StateObject(wrappedValue: ReadingStore(context: container.mainContext))
        } catch {
            _store = StateObject(wrappedValue: ReadingStore(context: nil, initializationError: "保存領域を開けませんでした。データを上書きせず停止しました。\(error.localizedDescription)"))
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
                .task { store.seedDemoIfNeeded(); store.refreshInbox() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.refreshInbox() }
                    else { store.setTiming("paused", article: store.selectedArticle) }
                }
        }
    }
}
