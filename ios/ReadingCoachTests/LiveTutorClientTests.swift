import Foundation
import ReadingCore
import XCTest
@testable import ReadingCoach

final class LiveTutorClientTests: XCTestCase {
    override func tearDown() {
        StubLiveURLProtocol.handler = nil
        super.tearDown()
    }

    func testRejectsHTTPBeforeSendingBearerToken() async {
        let client = makeClient(url: "http://private.example.test")
        StubLiveURLProtocol.handler = { _ in
            XCTFail("An insecure origin must receive no request")
            return (200, Data())
        }
        await expect(.invalidConfiguration) {
            _ = try await client.sendTurn(requestID: "request", runID: "run", stateRevision: 3,
                                          context: self.context, learnerTurn: "意味を説明して")
        }
    }

    func testAuthenticatedRequestAndValidReply() async throws {
        let expected = context
        StubLiveURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/tutor/turn")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-app-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Beta"))
            let body = try JSONSerialization.jsonObject(with: self.requestData(request)) as! [String: Any]
            XCTAssertEqual(body["stateRevision"] as? Int, 3)
            let sentContext = body["context"] as! [String: Any]
            XCTAssertEqual(sentContext["title"] as? String, expected.title)
            return (200, try self.reply())
        }
        let response = try await makeClient().sendTurn(requestID: "request", runID: "run", stateRevision: 3,
                                                       context: context, learnerTurn: "意味を説明して")
        XCTAssertEqual(response.feedbackJa, "これは説明です。")
        XCTAssertNil(response.assessment)
    }

    func testAuthenticationQuotaRateLimitAndTimeoutHaveDifferentOutcomes() async {
        for (status, expected) in [(401, LiveServiceError.authentication), (403, .authentication),
                                   (402, .quota), (429, .rateLimited), (504, .timeout), (503, .unavailable)] {
            StubLiveURLProtocol.handler = { _ in (status, Data("{}".utf8)) }
            await expect(expected) {
                _ = try await self.makeClient().sendTurn(requestID: "request", runID: "run", stateRevision: 3,
                                                         context: self.context, learnerTurn: "説明して")
            }
        }
        for (code, expected) in [("upstream_authentication_failed", LiveServiceError.authentication),
                                  ("insufficient_quota", .quota), ("invalid_source_or_revision", .invalidSource)] {
            StubLiveURLProtocol.handler = { _ in
                (502, try JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": "fixture"]]))
            }
            await expect(expected) {
                _ = try await self.makeClient().sendTurn(requestID: "request", runID: "run", stateRevision: 3,
                                                         context: self.context, learnerTurn: "説明して")
            }
        }
    }

    func testExpiredEphemeralCredentialIsRejectedBeforeSDPExchange() async {
        StubLiveURLProtocol.handler = { _ in
            (200, try JSONSerialization.data(withJSONObject: ["value": "fixture-ephemeral", "expiresAt": 1,
                                                               "model": "fixture-realtime", "sessionDurationSeconds": 600]))
        }
        await expect(.expiredCredential) {
            _ = try await self.makeClient().credential(runID: "run", stateRevision: 3, context: self.context, automatic: false)
        }
        StubLiveURLProtocol.handler = { _ in
            XCTFail("An expired credential must not be sent to OpenAI")
            return (500, Data())
        }
        await expect(.expiredCredential) {
            _ = try await self.makeClient().exchangeSDP("v=0\r\n", credential: LiveEphemeralCredential(
                value: "fixture-ephemeral", expiresAt: 1, model: "fixture-realtime", sessionDurationSeconds: 600))
        }
    }

    func testWrongRequestRunAndRevisionAreRejected() async {
        for change: [String: Any] in [["requestID": "old-request"], ["runID": "other-run"], ["stateRevision": 2]] {
            StubLiveURLProtocol.handler = { _ in (200, try self.reply(overrides: change)) }
            await expect(.staleResponse) {
                _ = try await self.makeClient().sendTurn(requestID: "request", runID: "run", stateRevision: 3,
                                                         context: self.context, learnerTurn: "説明して")
            }
        }
    }

    func testReplyCannotReferToAnotherSnapshot() async {
        let other = SourceRef(articleID: "article", snapshotID: "different-snapshot", blockID: "block", sentenceID: "sentence")
        StubLiveURLProtocol.handler = { _ in
            (200, try self.reply(overrides: ["sourceRefs": [self.json(other)]]))
        }
        await expect(.invalidSource) {
            _ = try await self.makeClient().sendTurn(requestID: "request", runID: "run", stateRevision: 3,
                                                     context: self.context, learnerTurn: "説明して")
        }
    }

    func testInvalidUTF16RangeIsRejectedBeforeNetwork() async {
        let bad = SourceRef(articleID: "article", snapshotID: "snapshot", blockID: "block", sentenceID: "sentence",
                            rangeUTF16: UTF16Range(location: Int.max, length: 2))
        let input = LiveTutorContext(title: "fixture", focus: bad,
                                     passages: [LiveSourcePassage(sourceRef: bad, blockText: "📘Original.", text: "Original.")])
        StubLiveURLProtocol.handler = { _ in
            XCTFail("Invalid source must not be transmitted")
            return (200, Data())
        }
        await expect(.invalidSource) {
            _ = try await self.makeClient().sendTurn(runID: "run", stateRevision: 3, context: input, learnerTurn: "説明して")
        }
    }

    func testGeneratedPracticeIsLabeledAndHasSeparateIdentity() async throws {
        StubLiveURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/practice")
            return (200, try JSONSerialization.data(withJSONObject: [
                "requestID": "request", "runID": "run", "stateRevision": 3, "feedbackJa": "別の練習文です。",
                "generatedPractice": ["id": "practice:fixture", "text": "Evidence may be useful without being conclusive.",
                                      "language": "en", "label": "generated_practice"]]))
        }
        let reply = try await makeClient().createPractice(requestID: "request", runID: "run", stateRevision: 3,
                                                          context: context, bottleneck: "logicalRelation")
        XCTAssertEqual(reply.generatedPractice.id, "practice:fixture")
        StubLiveURLProtocol.handler = { _ in
            (200, try JSONSerialization.data(withJSONObject: [
                "requestID": "request", "runID": "run", "stateRevision": 3, "feedbackJa": "bad fixture",
                "generatedPractice": ["id": "sentence", "text": "Original.", "language": "en", "label": "source"]]))
        }
        await expect(.malformedResponse) {
            _ = try await self.makeClient().createPractice(requestID: "request", runID: "run", stateRevision: 3,
                                                          context: self.context, bottleneck: "logicalRelation")
        }
    }

    func testPracticeAnswerRequestKeepsGeneratedTextSeparateFromSource() async throws {
        StubLiveURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: self.requestData(request)) as! [String: Any]
            XCTAssertEqual((body["practice"] as? [String: Any])?["label"] as? String, "generated_practice")
            XCTAssertEqual((body["practice"] as? [String: Any])?["id"] as? String, "practice:fixture")
            XCTAssertEqual((body["context"] as? [String: Any])?["title"] as? String, "Original sample")
            return (200, try self.reply())
        }
        _ = try await makeClient().sendTurn(requestID: "request", runID: "run", stateRevision: 3,
                                            context: context, learnerTurn: "可能性を述べています。", task: "assess",
                                            practice: LivePracticeContext(id: "practice:fixture", text: "It may be useful."))
    }

    private var context: LiveTutorContext {
        let ref = SourceRef(articleID: "article", snapshotID: "snapshot", blockID: "block", sentenceID: "sentence",
                            rangeUTF16: UTF16Range(location: 0, length: 9))
        return LiveTutorContext(title: "Original sample", focus: ref,
                                passages: [LiveSourcePassage(sourceRef: ref, blockText: "Original.", text: "Original.")])
    }

    private func makeClient(url: String = "https://private.example.test") -> LiveTutorClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubLiveURLProtocol.self]
        return LiveTutorClient(baseURL: URL(string: url)!, accessToken: "fixture-app-token", configuration: configuration)
    }

    private func reply(overrides: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["requestID": "request", "runID": "run", "stateRevision": 3,
                                    "intent": "explain", "feedbackJa": "これは説明です。", "sourceRefs": [try json(context.focus)],
                                    "assessment": NSNull(), "nextPromptJa": NSNull(), "generatedPractice": NSNull()]
        value.merge(overrides, uniquingKeysWith: { _, replacement in replacement })
        return try JSONSerialization.data(withJSONObject: value)
    }

    private func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func requestData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    private func expect(_ expected: LiveServiceError, operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let error as LiveServiceError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line) }
    }
}

private final class StubLiveURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) throws -> (Int, Data))?
    static var handler: ((URLRequest) throws -> (Int, Data))? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); defer { lock.unlock() }; storedHandler = newValue }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
