import Foundation

public enum VoiceState: String, Codable, Sendable {
    case disconnected, connecting, ready, listening, thinkingHold, waitingForTutor, tutorSpeaking, muted, suspended, error
}
public enum TurnMode: String, Codable, Sendable { case manual, automatic }
/// Derived only after final transcription. The transport must not classify partial transcripts as commands.
public enum TranscriptDecision: Sendable { case answer, hold, resume, requestExplanation, ambiguous, stop }
public enum VoiceEvent: Sendable {
    case connect, connected, startListening, hold, releaseHold, submit, vadStopped
    case finalTranscript(TranscriptDecision)
    case speechStarted(itemID: String), speechStopped(itemID: String)
    case transcriptFinal(itemID: String, decision: TranscriptDecision)
    case tutorStarted, tutorFinished, mute, unmute, suspend, resume, disconnect, failed, stop
    case setMode(TurnMode)
}
public enum VoiceEffect: String, Sendable {
    case none, allowResponse, cancelResponse, clarifyIntent, startMicrophone, stopMicrophone, connect
}
/// Transport state is deliberately separate from the learning reducer. Silence never releases a hold.
public struct VoiceGate: Codable, Sendable {
    public private(set) var state: VoiceState = .disconnected
    public private(set) var mode: TurnMode
    private var finalAnswerReceived = false
    private var speechStopped = false
    private var pendingSpeechIDs = Set<String>()
    private var stoppedSpeechIDs = Set<String>()
    private var finalSpeechIDs = Set<String>()
    private var speakingSpeechIDs = Set<String>()
    public init(mode: TurnMode = .manual) { self.mode = mode }
    public var microphoneMayTransmit: Bool { state == .listening || state == .thinkingHold }

    @discardableResult
    public mutating func handle(_ event: VoiceEvent) -> VoiceEffect {
        switch event {
        case .connect:
            guard state == .disconnected || state == .error else { return .none }
            clearDraftGate(); state = .connecting; return .connect
        case .connected:
            guard state == .connecting else { return .none }
            state = .ready
        case .startListening:
            guard state == .ready else { return .none }
            clearDraftGate(); state = .listening; return .startMicrophone
        case .hold:
            guard state == .listening || state == .waitingForTutor || state == .tutorSpeaking else { return .none }
            clearDraftGate(); state = .thinkingHold; return .cancelResponse
        case .releaseHold:
            guard state == .thinkingHold else { return .none }
            clearDraftGate(); state = .listening
        case .submit:
            guard state == .listening || state == .thinkingHold else { return .none }
            clearDraftGate(); state = .waitingForTutor; return .allowResponse
        case .vadStopped:
            guard state == .listening, mode == .automatic else { return .none }
            speechStopped = true
            return releaseAutomaticIfReady()
        case .finalTranscript(let decision):
            guard state == .listening || state == .thinkingHold else { return .none }
            switch decision {
            case .hold:
                clearDraftGate(); state = .thinkingHold; return .cancelResponse
            case .resume:
                guard state == .thinkingHold else { return .none }
                clearDraftGate(); state = .listening
            case .requestExplanation:
                clearDraftGate(); state = .waitingForTutor; return .allowResponse
            case .answer:
                guard state == .listening, mode == .automatic else { return .none }
                finalAnswerReceived = true
                return releaseAutomaticIfReady()
            case .ambiguous:
                clearDraftGate(); return .clarifyIntent
            case .stop:
                clearDraftGate(); state = .ready; return .cancelResponse
            }
        case .speechStarted(let itemID):
            guard !itemID.isEmpty, state == .listening || state == .thinkingHold else { return .none }
            pendingSpeechIDs.insert(itemID); speakingSpeechIDs.insert(itemID)
        case .speechStopped(let itemID):
            guard pendingSpeechIDs.contains(itemID) else { return .none }
            stoppedSpeechIDs.insert(itemID); speakingSpeechIDs.remove(itemID)
            return releaseTaggedAutomaticIfReady()
        case .transcriptFinal(let itemID, let decision):
            guard pendingSpeechIDs.contains(itemID) else { return .none }
            if case .answer = decision {
                finalSpeechIDs.insert(itemID)
                return releaseTaggedAutomaticIfReady()
            }
            // Explicit commands share the same hold/submit policy but never count as answer evidence.
            return handle(.finalTranscript(decision))
        case .tutorStarted:
            guard state == .waitingForTutor else { return .cancelResponse }
            state = .tutorSpeaking
        case .tutorFinished:
            guard state == .tutorSpeaking || state == .waitingForTutor else { return .none }
            state = .ready
        case .mute:
            guard state != .disconnected, state != .suspended else { return .none }
            clearDraftGate(); state = .muted; return .stopMicrophone
        case .unmute:
            // A UI operation is required: muted microphones cannot hear a resume command.
            guard state == .muted else { return .none }
            clearDraftGate(); state = .ready
        case .suspend:
            clearDraftGate(); state = .suspended; return .stopMicrophone
        case .resume:
            guard state == .suspended else { return .none }
            clearDraftGate(); state = .ready
        case .disconnect:
            clearDraftGate(); state = .disconnected; return .stopMicrophone
        case .failed:
            clearDraftGate(); state = .error; return .stopMicrophone
        case .stop:
            guard state != .disconnected, state != .suspended else { return .none }
            clearDraftGate(); state = .ready; return .cancelResponse
        case .setMode(let mode):
            self.mode = mode; clearDraftGate()
        }
        return .none
    }
    private mutating func clearDraftGate() {
        finalAnswerReceived = false; speechStopped = false
        pendingSpeechIDs.removeAll(); stoppedSpeechIDs.removeAll()
        finalSpeechIDs.removeAll(); speakingSpeechIDs.removeAll()
    }
    private mutating func releaseAutomaticIfReady() -> VoiceEffect {
        guard speechStopped, finalAnswerReceived, state == .listening else { return .none }
        clearDraftGate(); state = .waitingForTutor; return .allowResponse
    }
    private mutating func releaseTaggedAutomaticIfReady() -> VoiceEffect {
        guard state == .listening, mode == .automatic, !pendingSpeechIDs.isEmpty,
              speakingSpeechIDs.isEmpty, pendingSpeechIDs.isSubset(of: stoppedSpeechIDs),
              pendingSpeechIDs.isSubset(of: finalSpeechIDs) else { return .none }
        clearDraftGate(); state = .waitingForTutor; return .allowResponse
    }
}

public enum AudioOwner: String, Codable, Sendable { case none, source, tutor }
public enum AudioCommand: String, Sendable {
    case stopSource, stopTutorAndDiscardUnheard, disableMicrophone, startSource, startTutor, restoreMicrophone
}
/// Returns ordered adapter operations. Apply them in order on the AVAudioSession-owning actor.
public struct AudioArbiter: Codable, Sendable {
    public private(set) var owner: AudioOwner = .none
    public private(set) var microphoneEnabled = false
    public private(set) var activeSourceID: String?
    private var restoreAfterSource = false
    public init() {}

    public mutating func setMicrophoneEnabled(_ enabled: Bool) -> [AudioCommand] {
        guard owner != .source else {
            restoreAfterSource = enabled
            return []
        }
        microphoneEnabled = enabled
        return [enabled ? .restoreMicrophone : .disableMicrophone]
    }
    public mutating func beginSource(playbackID: String = UUID().uuidString) -> [AudioCommand] {
        var commands: [AudioCommand] = []
        if owner == .tutor { commands.append(.stopTutorAndDiscardUnheard) }
        if owner == .source { commands.append(.stopSource) }
        if owner != .source { restoreAfterSource = microphoneEnabled }
        microphoneEnabled = false; owner = .source; activeSourceID = playbackID
        commands += [.disableMicrophone, .startSource]
        return commands
    }
    public mutating func finishSource(playbackID: String? = nil) -> [AudioCommand] {
        guard owner == .source, playbackID == nil || playbackID == activeSourceID else { return [] }
        owner = .none; activeSourceID = nil
        microphoneEnabled = restoreAfterSource; restoreAfterSource = false
        return microphoneEnabled ? [.restoreMicrophone] : []
    }
    public mutating func beginTutor() -> [AudioCommand] {
        // A late tutor event must never cut into explicitly requested source playback.
        guard owner != .source else { return [.stopTutorAndDiscardUnheard] }
        owner = .tutor
        return [.startTutor]
    }
    public mutating func finishTutor() { if owner == .tutor { owner = .none } }
    public mutating func stop() -> [AudioCommand] {
        var commands: [AudioCommand] = []
        if owner == .source { commands.append(.stopSource) }
        if owner == .tutor { commands.append(.stopTutorAndDiscardUnheard) }
        owner = .none; microphoneEnabled = false; restoreAfterSource = false; activeSourceID = nil
        commands.append(.disableMicrophone)
        return commands
    }
}
