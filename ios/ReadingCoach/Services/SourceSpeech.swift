import AVFoundation
import Combine
import Foundation
import ReadingCore
import UIKit

@MainActor
final class SourceSpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Speed: String, CaseIterable { case slow = "ゆっくり", normal = "標準", fast = "速め"
        var rate: Float { switch self { case .slow: 0.38; case .normal: AVSpeechUtteranceDefaultSpeechRate; case .fast: 0.58 } }
    }
    @Published var speed = Speed.normal
    @Published private(set) var playingSource: SourceRef?
    @Published private(set) var wordRange: SourceRef?
    @Published private(set) var isPaused = false
    @Published var errorMessage: String?
    var onWillPlay: (() -> Void)?
    var onFinished: (() -> Void)?
    var onSourceFinished: ((SourceRef) -> Void)?
    var onInterrupted: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var sourceQueue: [(SourceRef, SourceResolver)] = []
    private var currentResolver: SourceResolver?
    private var utteranceID: ObjectIdentifier?
    private var ownsAudio = false
    private var notifications: [NSObjectProtocol] = []

    override init() {
        super.init(); synthesizer.delegate = self
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification, UIApplication.didEnterBackgroundNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if notification.name == AVAudioSession.routeChangeNotification {
                    let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                }
                Task { @MainActor [weak self] in self?.interrupt() }
            })
        }
    }

    deinit { for notification in notifications { NotificationCenter.default.removeObserver(notification) } }

    func play(_ refs: [SourceRef], snapshot: ArticleSnapshot) {
        stop()
        let resolver = SourceResolver(snapshot: snapshot)
        do {
            _ = try refs.map(resolver.resolve)
            guard AVSpeechSynthesisVoice(language: "en-US") != nil else {
                errorMessage = "利用できる英語音声がありません。設定から音声を追加してください。本文はそのまま読めます。"; return
            }
            onWillPlay?()
            ownsAudio = true
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audio.setActive(true)
            sourceQueue = refs.map { ($0, resolver) }
            playNext()
        } catch { errorMessage = "原文を再生できませんでした。\(error.localizedDescription)"; finish() }
    }

    func pauseOrResume() {
        if synthesizer.isPaused { _ = synthesizer.continueSpeaking(); isPaused = false }
        else if synthesizer.isSpeaking { _ = synthesizer.pauseSpeaking(at: .word); isPaused = true }
    }

    func stop() {
        utteranceID = nil
        sourceQueue = []
        _ = synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    func interrupt() {
        onInterrupted?()
        let completion = onFinished
        onFinished = nil
        stop()
        onFinished = completion
    }

    private func playNext() {
        guard !sourceQueue.isEmpty else { finish(); return }
        let (ref, resolver) = sourceQueue.removeFirst()
        do {
            let utterance = AVSpeechUtterance(string: try resolver.resolve(ref).text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = speed.rate
            playingSource = ref
            wordRange = nil
            currentResolver = resolver
            utteranceID = ObjectIdentifier(utterance)
            synthesizer.speak(utterance)
        } catch { errorMessage = "保存済み原文の参照が無効です。"; finish() }
    }

    private func finish() {
        let shouldRelease = ownsAudio
        ownsAudio = false
        playingSource = nil
        wordRange = nil
        isPaused = false
        currentResolver = nil
        if shouldRelease { onFinished?() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.utteranceID == id else { return }
            if let ref = self.playingSource { self.onSourceFinished?(ref) }
            self.playNext()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.utteranceID == id, let ref = self.playingSource, let resolver = self.currentResolver else { return }
            self.wordRange = try? resolver.playbackRange(UTF16Range(location: characterRange.location, length: characterRange.length), for: ref)
        }
    }
}
