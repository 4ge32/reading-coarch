import Foundation
import ReadingCore

struct LiveSourcePassage: Codable, Sendable {
    let sourceRef: SourceRef
    let blockText: String
    let text: String
}

struct LiveTutorContext: Codable, Sendable {
    let title: String
    let focus: SourceRef
    let passages: [LiveSourcePassage]
    var explanationSeen: Bool = false
    var hintSeen: Bool = false
    var inputModality: String = "text"
    var presentation: String = "reading"
    var recentTurns: [LiveRecentTurn] = []
}

struct LiveRecentTurn: Codable, Sendable {
    let role: String
    let text: String
}

struct LivePracticeReply: Codable, Sendable {
    let requestID: String
    let runID: String
    let stateRevision: Int
    let generatedPractice: LiveTutorReply.GeneratedPractice
    let feedbackJa: String
}

struct LivePracticeContext: Codable, Sendable {
    let id: String
    let text: String
    var label: String = "generated_practice"
    var language: String = "en"
}

struct LiveTutorReply: Codable, Sendable {
    let requestID: String
    let runID: String
    let stateRevision: Int
    let intent: String
    let feedbackJa: String
    let sourceRefs: [SourceRef]
    let assessment: Assessment?
    let nextPromptJa: String?
    let generatedPractice: GeneratedPractice?

    struct Assessment: Codable, Sendable {
        let outcome: String
        let matchedPoints: [String]
        let missedPoints: [String]
        let bottleneck: String
    }
    struct GeneratedPractice: Codable, Sendable {
        let id: String?
        let text: String
        let language: String
        let label: String
    }
}

struct LiveEphemeralCredential: Decodable, Sendable {
    let value: String
    let expiresAt: TimeInterval
    let model: String
    let sessionDurationSeconds: Int
}

enum LiveServiceError: LocalizedError, Equatable {
    case invalidConfiguration, authentication, quota, rateLimited, unavailable, timeout
    case malformedResponse, staleResponse, invalidSource, expiredCredential, microphoneDenied
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "HTTPSのサーバーURLと端末アクセストークンを設定してください。"
        case .authentication: "認証できません。端末アクセストークンを確認してください。"
        case .quota: "APIの利用枠に達しました。記事とマークは引き続き利用できます。"
        case .rateLimited: "要求が多すぎます。少し待って再接続してください。"
        case .unavailable: "Liveサービスを利用できません。サーバーとモデルの設定を確認してください。"
        case .timeout: "Liveへの接続がタイムアウトしました。再接続してください。"
        case .malformedResponse: "Liveから有効な応答を受信できませんでした。状態は更新していません。"
        case .staleResponse: "対象が変わったため、以前の応答を破棄しました。"
        case .invalidSource: "応答の出典が保存済みの対象文と一致しません。"
        case .expiredCredential: "音声接続の資格情報が期限切れです。再接続してください。"
        case .microphoneDenied: "音声会話にはマイクの許可が必要です。設定から変更できます。"
        case .transport: "音声接続が切れました。内容を確認し、操作して再接続してください。"
        }
    }
}

/// Uses an ephemeral URLSession with no cookies/cache and refuses redirects with bearer credentials.
final class LiveTutorClient: @unchecked Sendable {
    let baseURL: URL
    private let accessToken: String
    private let session: URLSession
    private let redirectGuard = LiveRedirectGuard()

    init(baseURL: URL, accessToken: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 45
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
    }

    func sendTurn(requestID: String = UUID().uuidString, runID: String, stateRevision: Int,
                  context: LiveTutorContext, learnerTurn: String, task: String = "tutor",
                  practice: LivePracticeContext? = nil) async throws -> LiveTutorReply {
        struct Request: Encodable {
            let requestID: String; let runID: String; let stateRevision: Int
            let context: LiveTutorContext; let learnerTurn: String; let task: String
            let practice: LivePracticeContext?
        }
        try validate(context)
        let reply: LiveTutorReply = try await post("v1/tutor/turn", body: Request(
            requestID: requestID, runID: runID, stateRevision: stateRevision,
            context: context, learnerTurn: learnerTurn, task: task, practice: practice))
        guard reply.requestID == requestID, reply.runID == runID, reply.stateRevision == stateRevision else {
            throw LiveServiceError.staleResponse
        }
        guard ["clarify", "explain", "assess", "practice", "navigate", "pause"].contains(reply.intent),
              reply.sourceRefs.allSatisfy({ ref in context.passages.contains { $0.sourceRef == ref } }),
              reply.assessment.map({ ["meaningMatched", "partiallyMatched", "meaningMismatch", "uncertain"].contains($0.outcome) }) ?? true,
              reply.generatedPractice.map({ $0.label == "generated_practice" && $0.language == "en" }) ?? true else {
            throw LiveServiceError.invalidSource
        }
        return reply
    }

    func credential(requestID: String = UUID().uuidString, runID: String, stateRevision: Int,
                    context: LiveTutorContext, automatic: Bool) async throws -> LiveEphemeralCredential {
        struct Request: Encodable {
            let requestID: String; let runID: String; let stateRevision: Int
            let context: LiveTutorContext; let turnMode: String
        }
        try validate(context)
        let token: LiveEphemeralCredential = try await post("v1/realtime/token", body: Request(
            requestID: requestID, runID: runID, stateRevision: stateRevision,
            context: context, turnMode: automatic ? "automatic" : "manual"))
        guard !token.value.isEmpty, token.expiresAt > Date().timeIntervalSince1970,
              token.sessionDurationSeconds > 0 else { throw LiveServiceError.expiredCredential }
        return token
    }

    func createPractice(requestID: String = UUID().uuidString, runID: String, stateRevision: Int,
                        context: LiveTutorContext, bottleneck: String) async throws -> LivePracticeReply {
        struct Request: Encodable {
            let requestID: String; let runID: String; let stateRevision: Int
            let context: LiveTutorContext; let bottleneck: String
        }
        try validate(context)
        let reply: LivePracticeReply = try await post("v1/practice", body: Request(requestID: requestID,
            runID: runID, stateRevision: stateRevision, context: context, bottleneck: bottleneck))
        guard reply.requestID == requestID, reply.runID == runID, reply.stateRevision == stateRevision else {
            throw LiveServiceError.staleResponse
        }
        guard reply.generatedPractice.id?.hasPrefix("practice:") == true,
              reply.generatedPractice.label == "generated_practice", reply.generatedPractice.language == "en" else {
            throw LiveServiceError.malformedResponse
        }
        return reply
    }

    /// Only the short-lived credential goes to OpenAI. APP_ACCESS_TOKEN stays on the configured backend origin.
    func exchangeSDP(_ offer: String, credential: LiveEphemeralCredential) async throws -> String {
        guard credential.expiresAt > Date().timeIntervalSince1970 else { throw LiveServiceError.expiredCredential }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/calls")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(offer.utf8)
        let data = try await perform(request)
        guard let answer = String(data: data, encoding: .utf8), answer.hasPrefix("v=0") else {
            throw LiveServiceError.malformedResponse
        }
        return answer
    }

    private func post<Body: Encodable, Reply: Decodable>(_ path: String, body: Body) async throws -> Reply {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, !accessToken.isEmpty else {
            throw LiveServiceError.invalidConfiguration
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        do { return try JSONDecoder().decode(Reply.self, from: await perform(request)) }
        catch let error as LiveServiceError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw LiveServiceError.malformedResponse }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .timedOut { throw LiveServiceError.timeout }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw LiveServiceError.transport("network") }
        guard let http = response as? HTTPURLResponse else { throw LiveServiceError.malformedResponse }
        guard data.count <= 512_000 else { throw LiveServiceError.malformedResponse }
        if !(200..<300).contains(http.statusCode),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = payload["error"] as? [String: Any], let code = detail["code"] as? String {
            // Read only documented machine codes. Upstream text can contain private request details.
            if ["upstream_quota_exceeded", "insufficient_quota", "billing_hard_limit_reached"].contains(code) {
                throw LiveServiceError.quota
            }
            if ["upstream_authentication_failed", "invalid_api_key", "authentication_failed"].contains(code) {
                throw LiveServiceError.authentication
            }
            if code == "invalid_source_or_revision" { throw LiveServiceError.invalidSource }
        }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw LiveServiceError.authentication
        case 402: throw LiveServiceError.quota
        case 429: throw LiveServiceError.rateLimited
        case 408, 504: throw LiveServiceError.timeout
        default: throw LiveServiceError.unavailable
        }
        return data
    }

    private func validate(_ context: LiveTutorContext) throws {
        guard !context.passages.isEmpty, context.passages.count <= 12,
              context.passages.contains(where: { $0.sourceRef == context.focus }) else {
            throw LiveServiceError.invalidSource
        }
        for passage in context.passages {
            let ref = passage.sourceRef
            guard ref.articleID == context.focus.articleID, ref.snapshotID == context.focus.snapshotID else {
                throw LiveServiceError.invalidSource
            }
            if let range = ref.rangeUTF16 {
                guard let stored = try? range.substring(in: passage.blockText), stored == passage.text else {
                    throw LiveServiceError.invalidSource
                }
            } else if passage.text != passage.blockText { throw LiveServiceError.invalidSource }
        }
    }
}

private final class LiveRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
