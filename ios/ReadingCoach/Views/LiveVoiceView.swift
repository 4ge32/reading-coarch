import SwiftUI

struct LiveVoiceView: View {
    @ObservedObject var session: LiveVoiceSession
    @State private var editedTranscript = ""
    @State private var editing = false
    @State private var consent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Live：音声と対象文を外部APIへ送信", systemImage: "network")
                .font(.headline)
            Text("音声と記事の一部は外部APIに送信されます。このアプリと独自サーバーは生音声を保存しません。事業者の保持方針は別途ご確認ください。")
                .font(.caption)
            Toggle("外部送信を確認しました", isOn: $consent)
                .disabled(session.state != .disconnected && session.state != .suspended && session.state != .error)
            Label(session.state.label, systemImage: session.microphoneSending ? "mic.fill" : "mic.slash")
                .accessibilityIdentifier("liveVoiceState")
            Toggle("自動会話（発話確定後に応答）", isOn: Binding(get: { session.automatic }, set: session.setAutomatic))
            Text("手動では「回答を送る」で確定。考え中は待機を使ってください。待機中もマイク送信が続き、接続の利用費が発生することがあります。")
                .font(.caption)
            if let warning = session.sessionWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
            if let error = session.errorMessage { Text(error).foregroundStyle(.red).accessibilityIdentifier("liveVoiceError") }
            if [.disconnected, .suspended, .error].contains(session.state) {
                Button("Live音声に接続", systemImage: "mic") { session.connect() }.disabled(!consent)
            } else {
                HStack {
                    Button("回答を送る") { session.sendAnswer() }
                    Button(session.state == .thinkingHold ? "待機解除" : "待機") {
                        if session.state == .thinkingHold { session.releaseHold() } else { session.enterHold() }
                    }
                }
                HStack {
                    Button(session.state == .muted ? "マイク再開" : "マイクOFF") {
                        if session.state == .muted { session.resumeMicrophone() } else { session.mute() }
                    }
                    Button("止める", role: .destructive) { session.stop() }
                    Button("切断") { session.disconnect() }
                }
            }
            if !session.transcript.isEmpty {
                Text("転記（読解評価とは別）").font(.caption.bold())
                Text(session.transcript).textSelection(.enabled)
                Button("転記を訂正") { editedTranscript = session.transcript; editing = true }
            }
            if !session.tutorText.isEmpty {
                Text("AIの説明（原文ではありません）").font(.caption.bold())
                Text(session.tutorText).textSelection(.enabled)
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                VStack {
                    Text("訂正前の評価は無効になります。訂正を保存後、内容を確認して送信してください。")
                    TextEditor(text: $editedTranscript).padding()
                }.padding()
                    .navigationTitle("転記の訂正")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { editing = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") { session.correctTranscript(editedTranscript); editing = false }
                                .disabled(editedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }
        }
        .onDisappear { session.suspend() }
    }
}
