import Testing
import Foundation
@testable import AgyAgentKit

@Suite("Integração Responses do Codex")
struct CodexIntegrationTests {
    final class TimeBox: @unchecked Sendable { var value: Date; init(_ value: Date) { self.value = value } }
    @Test("Extrai instruções, mensagens e cwd do pedido")
    func parsesRequest() throws {
        let directory = try TemporaryDirectory()
        let data = try JSONSerialization.data(withJSONObject: [
            "model": "gemini_worker",
            "instructions": "Leia com atenção",
            "cwd": directory.url.path,
            "stream": true,
            "input": [["role": "user", "content": [["type": "input_text", "text": "responda OK"]]]]
        ])
        let request = try CodexResponsesRequest(data: data, fallbackDirectory: URL(filePath: "/tmp", directoryHint: .isDirectory))
        #expect(request.model == "gemini_worker")
        #expect(request.prompt.contains("Leia com atenção"))
        #expect(request.prompt.contains("responda OK"))
        #expect(request.workingDirectory == directory.url)
        #expect(request.streaming)
    }

    @Test("Mapeia modelos virtuais a papéis e modos")
    func mapsRoles() {
        #expect(CodexRole.resolve(model: "gemini_worker") == .worker)
        #expect(CodexRole.resolve(model: "gemini_explorer") == .explorer)
        #expect(CodexRole.resolve(model: "gemini_reviewer") == .reviewer)
        #expect(CodexRole.explorer.mode == "plan")
        #expect(CodexRole.worker.mode == "accept-edits")
    }

    @Test("Opções de job preservam timeout e orçamento anunciados pelo MCP")
    func parsesDelegateOptions() throws {
        let options = try CodexDelegateOptions.parse([
            "gemini_reviewer", "--timeout", "75", "--budget", "900"
        ])
        #expect(options.role == .reviewer)
        #expect(options.timeoutSeconds == 75)
        #expect(options.responseBudget == 900)
        #expect(options.childArguments == [
            "codex-delegate", "gemini_reviewer", "--timeout", "75", "--budget", "900",
        ])
        #expect(throws: AgyAgentError.self) {
            try CodexDelegateOptions.parse(["gemini_worker", "--timeout", "901"])
        }
    }

    @Test("Serializa eventos Responses em SSE e mantém texto")
    func serializesSSE() throws {
        let value = String(decoding: CodexResponses.stream(model: "gemini_worker", text: "OK"), as: UTF8.self)
        #expect(value.contains("response.output_text.delta"))
        #expect(value.contains("response.output_item.added"))
        #expect(value.contains("response.content_part.added"))
        #expect(value.contains("\"delta\":\"OK\""))
        #expect(value.contains("response.completed"))
        #expect(value.hasSuffix("data: [DONE]\n\n"))
    }

    @Test("Proxy exige caminho imprevisível para aceitar delegação")
    func proxyRequiresPathToken() {
        let token = String(repeating: "a", count: 64)
        #expect(CodexProxyServer.accepts(requestLine: "POST /\(token)/v1/responses HTTP/1.1", pathToken: token))
        #expect(!CodexProxyServer.accepts(requestLine: "POST /v1/responses HTTP/1.1", pathToken: token))
        #expect(!CodexProxyServer.accepts(requestLine: "POST /\(String(repeating: "b", count: 64))/v1/responses HTTP/1.1", pathToken: token))
    }

    @Test("Proxy recusa DNS rebinding, Origin web e corpo chunked")
    func proxyValidatesHeaders() {
        let valid = "POST /x HTTP/1.1\r\nHost: 127.0.0.1:47321\r\nContent-Type: application/json\r\nContent-Length: 2"
        #expect(CodexProxyServer.accepts(headers: valid, port: 47321))
        #expect(CodexProxyServer.accepts(headers: valid.replacingOccurrences(of: "127.0.0.1", with: "localhost"), port: 47321))
        #expect(!CodexProxyServer.accepts(headers: valid.replacingOccurrences(of: "127.0.0.1:47321", with: "attacker.example"), port: 47321))
        #expect(!CodexProxyServer.accepts(headers: valid + "\r\nOrigin: https://attacker.example", port: 47321))
        #expect(!CodexProxyServer.accepts(headers: valid + "\r\nTransfer-Encoding: chunked", port: 47321))
    }

    @Test("Disjuntor abre após três falhas e reseta após sucesso")
    func circuitBreaker() {
        let time = TimeBox(Date(timeIntervalSince1970: 100))
        let breaker = CodexCircuitBreaker(clock: { time.value })
        #expect(breaker.check() == nil)
        breaker.recordFailure(); breaker.recordFailure(); breaker.recordFailure()
        #expect(breaker.check() != nil)
        time.value = time.value.addingTimeInterval(901)
        #expect(breaker.check() == nil)
        breaker.recordFailure(); breaker.recordSuccess()
        #expect(breaker.check() == nil)
    }

    @Test("Classifica código 3 e AGY_ERROR como cota")
    func classifiesQuota() {
        #expect(CodexFailureClassification.isQuota(exitCode: 3, stderr: ""))
        #expect(CodexFailureClassification.isQuota(exitCode: 1, stderr: "AGY_ERROR quota"))
        #expect(!CodexFailureClassification.isQuota(exitCode: 1, stderr: "falha de rede"))
    }

    @Test("Invoker recusa anexar o diretório home inteiro")
    func invokerRejectsHomeWorkspace() throws {
        let home = try TemporaryDirectory()
        let invoker = CodexAgyInvoker(
            executable: URL(filePath: "/bin/echo", directoryHint: .notDirectory),
            environment: ["HOME": home.url.path(percentEncoded: false)]
        )
        let request = CodexResponsesRequest(
            model: CodexRole.worker.rawValue,
            prompt: "teste",
            workingDirectory: home.url,
            streaming: false
        )
        #expect(throws: AgyAgentError.self) {
            try invoker.invoke(request, role: .worker, processRunner: FakeProcessRunner(standardOutput: ""))
        }
    }

    @Test("Invoker limita o texto devolvido ao chamador")
    func invokerCapsResponse() throws {
        let workspace = try TemporaryDirectory()
        let result: [String: Any] = [
            "conversation_id": "test",
            "status": "SUCCESS",
            "response": String(repeating: "x", count: DelegationRequest.maximumResponseBudget + 500),
            "duration_seconds": 1,
            "num_turns": 1,
            "usage": ["total_tokens": 10]
        ]
        let event = try JSONSerialization.data(withJSONObject: ["event": "result", "result": result])
        let fake = FakeProcessRunner(standardOutput: String(decoding: event, as: UTF8.self) + "\n")
        let request = CodexResponsesRequest(model: CodexRole.worker.rawValue, prompt: "teste", workingDirectory: workspace.url, streaming: false)
        let envelope = try CodexAgyInvoker(
            executable: URL(filePath: "/bin/echo", directoryHint: .notDirectory),
            environment: ["HOME": "/Users/tester"],
            timeout: .seconds(42),
            responseBudget: 200
        ).invoke(request, role: .worker, processRunner: fake)
        #expect(envelope.response.count < 500)
        #expect(envelope.response.contains("resposta cortada"))
        #expect(fake.plans.last?.arguments.contains("42s") == true)
    }

    @Test("Gate de concorrência mantém no máximo dois slots")
    func concurrencyGate() throws {
        let directory = try TemporaryDirectory()
        let gate = CodexConcurrencyGate(directory: directory.url, maximum: 2)
        let first = gate.acquire()
        let second = gate.acquire()
        #expect(first != nil)
        #expect(second != nil)
        #expect(gate.acquire() == nil)
        if let first { gate.release(first) }
        let replacement = gate.acquire()
        #expect(replacement != nil)
        if let second { gate.release(second) }
        if let replacement { gate.release(replacement) }
    }

    @Test("Duas instâncias removem apenas seus próprios slots e stale PID é recuperado")
    func processSafeSlots() throws {
        let directory = try TemporaryDirectory()
        let first = CodexConcurrencyGate(directory: directory.url, maximum: 2)
        let second = CodexConcurrencyGate(directory: directory.url, maximum: 2)
        let firstLease = first.acquire()
        let secondLease = second.acquire()
        #expect(firstLease != nil); #expect(secondLease != nil)
        if let firstLease { first.release(firstLease) }
        let replacement = second.acquire()
        #expect(replacement != nil)
        if let secondLease { second.release(secondLease) }
        if let replacement { second.release(replacement) }
        try Data("999999\n".utf8).write(to: directory.url.appending(path: "slot-0.lock"))
        let recovered = first.acquire()
        #expect(recovered != nil)
        if let recovered { first.release(recovered) }
    }

    @Test("Disjuntor persistente atravessa instâncias e respeita cooldown")
    func persistentCircuitBreaker() throws {
        let directory = try TemporaryDirectory()
        let time = TimeBox(Date(timeIntervalSince1970: 100))
        let state = directory.url.appending(path: "circuit.json")
        let first = CodexCircuitBreaker(stateURL: state, clock: { time.value })
        first.recordFailure(); first.recordFailure(); first.recordFailure()
        let second = CodexCircuitBreaker(stateURL: state, clock: { time.value })
        #expect(second.check() != nil)
        time.value = time.value.addingTimeInterval(901)
        #expect(second.check() == nil)
    }
}
