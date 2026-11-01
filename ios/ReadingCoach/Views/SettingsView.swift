import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ReadingStore
    @AppStorage("connectionMode") private var mode = ConnectionMode.demo.rawValue
    @AppStorage("backendURL") private var backendURL = ""
    @AppStorage("liveConsent") private var consent = false
    @State private var token = ""
    @State private var status: String?
    @State private var deleteConfirmation = false
    var body: some View {
        NavigationStack {
            Form {
                Section("接続モード") {
                    Picker("モード", selection: $mode) { ForEach(ConnectionMode.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } }
                    Text("Demoは固定のサンプル応答です。Liveの失敗時にDemoへ自動で切り替わることはありません。").font(.caption)
                }
                Section("Live接続（private MVP）") {
                    TextField("https://your-private-server.example", text: $backendURL).textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("端末アクセストークン", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("トークンをKeychainに保存") { store.perform { try KeychainAccessToken.save(token); token = ""; status = "保存しました。" } }.disabled(token.isEmpty)
                    Button("保存したトークンを削除", role: .destructive) { store.perform { try KeychainAccessToken.delete(); status = "削除しました。" } }
                    if let status { Text(status).font(.caption) }
                    Toggle("外部送信を理解しLiveを許可", isOn: $consent)
                    Text("Liveでは選んだ文・周辺の限定した本文・回答・マイク音声を外部APIへ送信します。アプリと独自サーバーは生音声を保存しません。API事業者側の取り扱いはその保存ポリシーに従います。端末だけで処理される機能ではありません。").font(.caption)
                    Text("公開配布用の認証ではありません。OpenAIの通常APIキーはこの端末に設定しないでください。").font(.caption)
                }
                Section("時間と原文") {
                    Text("読書時間は画面表示に基づく目安です。初読・再読・対話・原文音声・休止を分離し、WPMは完読した区間にのみ表示します。").font(.caption)
                    Text("原文は取り込み時に固定します。再取り込みは新しい版となり、既存のマークを自動で移動しません。").font(.caption)
                }
                Section("データ") {
                    Button("記事・学習履歴・受信トレイを全削除", role: .destructive) { deleteConfirmation = true }
                    Text("端末アクセストークンは上の操作で別に削除できます。").font(.caption)
                }
            }
            .navigationTitle("設定")
            .confirmationDialog("すべての記事と関連する学習履歴を削除しますか？", isPresented: $deleteConfirmation, titleVisibility: .visible) {
                Button("すべて削除", role: .destructive) { store.deleteAll() }
            }
        }
    }
}
