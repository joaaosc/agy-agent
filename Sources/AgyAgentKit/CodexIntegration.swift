import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Papéis expostos ao Codex. Os nomes são modelos virtuais; o modelo real é
/// escolhido aqui para que a configuração do Codex não conheça o `agy`.
public enum CodexRole: String, CaseIterable, Sendable {
    case worker = "gemini_worker"
    case explorer = "gemini_explorer"
    case reviewer = "gemini_reviewer"

    public var model: String { "gemini-3.8-flash-high" }
    public var agent: String {
        switch self {
        case .worker: "default"
        case .explorer, .reviewer: "agy-leitor"
        }
    }
    public var mode: String {
        switch self {
        case .worker: "accept-edits"
        case .explorer, .reviewer: "plan"
        }
    }
    public var sandboxed: Bool { true }

    public static func resolve(model: String) -> CodexRole {
        switch model.lowercased() {
        case "gemini_explorer", "gemini-explorer", "explorer", "reviewer", "gemini_reviewer", "gemini-reviewer":
            return model.lowercased().contains("review") || model.lowercased() == "reviewer" ? .reviewer : .explorer
        default: return .worker
        }
    }
}

/// Opções do processo interno usado pelos jobs MCP. O parser fica no módulo
/// testável para que limites anunciados no schema não sejam ignorados na CLI.
public struct CodexDelegateOptions: Sendable, Equatable {
    public static let maximumTimeoutSeconds = 900

    public var role: CodexRole
    public var timeoutSeconds: Int
    public var responseBudget: Int
    public var questionParts: [String]

    public init(
        role: CodexRole,
        timeoutSeconds: Int = maximumTimeoutSeconds,
        responseBudget: Int = DelegationRequest.maximumResponseBudget,
        questionParts: [String] = []
    ) throws {
        guard (1...Self.maximumTimeoutSeconds).contains(timeoutSeconds) else {
            throw AgyAgentError.invalidConfiguration(
                "timeout deve ficar entre 1 e \(Self.maximumTimeoutSeconds) segundos"
            )
        }
        guard (1...DelegationRequest.maximumResponseBudget).contains(responseBudget) else {
            throw AgyAgentError.invalidResponseBudget(
                requested: responseBudget,
                maximum: DelegationRequest.maximumResponseBudget
            )
        }
        self.role = role
        self.timeoutSeconds = timeoutSeconds
        self.responseBudget = responseBudget
        self.questionParts = questionParts
    }

    public static func parse(_ arguments: [String]) throws -> CodexDelegateOptions {
        guard let roleName = arguments.first, let role = CodexRole(rawValue: roleName) else {
            throw AgyAgentError.invalidConfiguration(
                "papel deve ser gemini_worker, gemini_explorer ou gemini_reviewer"
            )
        }
        var timeout = Self.maximumTimeoutSeconds
        var budget = DelegationRequest.maximumResponseBudget
        var questionParts: [String] = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                questionParts.append(contentsOf: arguments[(index + 1)...])
                break
            }
            switch argument {
            case "--timeout":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw AgyAgentError.invalidConfiguration("--timeout exige um inteiro")
                }
                timeout = value
            case "--budget":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw AgyAgentError.invalidConfiguration("--budget exige um inteiro")
                }
                budget = value
            default:
                guard !argument.hasPrefix("-") else {
                    throw AgyAgentError.invalidConfiguration("opção desconhecida: \(argument)")
                }
                questionParts.append(argument)
            }
            index += 1
        }
        return try CodexDelegateOptions(
            role: role,
            timeoutSeconds: timeout,
            responseBudget: budget,
            questionParts: questionParts
        )
    }

    public var childArguments: [String] {
        [
            "codex-delegate", role.rawValue,
            "--timeout", String(timeoutSeconds),
            "--budget", String(responseBudget),
        ]
    }
}

/// Parte relevante do pedido Responses. O Codex envia mensagens e texto de
/// instruções; manter o parser tolerante permite mudanças de versão do CLI.
public struct CodexResponsesRequest: Sendable, Equatable {
    public let model: String
    public let prompt: String
    public let workingDirectory: URL
    public let streaming: Bool

    public init(model: String, prompt: String, workingDirectory: URL, streaming: Bool) {
        self.model = model
        self.prompt = prompt
        self.workingDirectory = DirectoryURL.normalized(workingDirectory)
        self.streaming = streaming
    }

    public init(data: Data, fallbackDirectory: URL) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgyAgentError.invalidConfiguration("pedido Responses não é um objeto JSON")
        }
        let model = (object["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? CodexRole.worker.rawValue
        let instructions = object["instructions"] as? String ?? ""
        var sections: [String] = []
        if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sections.append(instructions) }
        if let input = object["input"] { sections.append(Self.text(from: input)) }
        let prompt = sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw AgyAgentError.emptyQuestion }
        let rawDirectory = (object["cwd"] as? String)
            ?? ((object["metadata"] as? [String: Any])?["cwd"] as? String)
            ?? Self.cwdInPrompt(prompt)
        let directory: URL
        if let rawDirectory, !rawDirectory.isEmpty {
            let candidate = URL(filePath: rawDirectory, directoryHint: .isDirectory)
            guard candidate.path(percentEncoded: false).hasPrefix("/") else {
                throw AgyAgentError.invalidConfiguration("cwd deve ser absoluto")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue else {
                throw AgyAgentError.invalidConfiguration("cwd não é um diretório")
            }
            directory = candidate
        } else {
            directory = fallbackDirectory
        }
        self.init(model: model, prompt: prompt, workingDirectory: directory, streaming: object["stream"] as? Bool ?? true)
    }

    private static func cwdInPrompt(_ text: String) -> String? {
        guard let range = text.range(of: "<cwd>"), let end = text.range(of: "</cwd>", range: range.upperBound..<text.endIndex) else { return nil }
        return String(text[range.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func text(from value: Any) -> String {
        if let text = value as? String { return text }
        if let array = value as? [Any] { return array.map(text(from:)).filter { !$0.isEmpty }.joined(separator: "\n") }
        if let object = value as? [String: Any] {
            if let text = object["text"] as? String { return text }
            if let content = object["content"] { return text(from: content) }
            return object.keys.sorted().compactMap { key in text(from: object[key] as Any) }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return ""
    }
}

/// Codificação mínima do formato SSE que o Codex Responses consome.
public enum CodexResponses {
    public static func json(_ value: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(#"{"error":{"message":"falha de serialização"}}"#.utf8)
    }

    public static func stream(id: String = "resp_\(UUID().uuidString.lowercased())", model: String, text: String, error: String? = nil) -> Data {
        let itemID = "msg_\(id)"
        let outputText: [String: Any] = ["type": "output_text", "text": text, "annotations": []]
        let outputItem: [String: Any] = [
            "id": itemID,
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [outputText]
        ]
        let completedStatus = error == nil ? "completed" : "failed"
        let completedResponse: [String: Any] = [
            "id": id,
            "object": "response",
            "status": completedStatus,
            "model": model,
            "output": error == nil ? [outputItem] : [],
            "output_text": text,
            "error": error.map { ["message": $0, "type": "server_error"] } ?? NSNull()
        ]
        let startedResponse: [String: Any] = [
            "id": id,
            "object": "response",
            "status": "in_progress",
            "model": model,
            "output": []
        ]
        var events: [[String: Any]] = [["type": "response.created", "response": startedResponse]]
        if let error {
            events.append(["type": "error", "error": ["message": error, "type": "server_error"]])
        } else {
            let inProgressItem: [String: Any] = [
                "id": itemID,
                "type": "message",
                "status": "in_progress",
                "role": "assistant",
                "content": []
            ]
            events.append(["type": "response.output_item.added", "output_index": 0, "item": inProgressItem])
            events.append(["type": "response.content_part.added", "item_id": itemID, "output_index": 0, "content_index": 0, "part": ["type": "output_text", "text": "", "annotations": []]])
            events.append(["type": "response.output_text.delta", "item_id": itemID, "output_index": 0, "content_index": 0, "delta": text])
            events.append(["type": "response.output_text.done", "item_id": itemID, "output_index": 0, "content_index": 0, "text": text])
            events.append(["type": "response.content_part.done", "item_id": itemID, "output_index": 0, "content_index": 0, "part": outputText])
            events.append(["type": "response.output_item.done", "output_index": 0, "item": outputItem])
        }
        events.append(["type": "response.completed", "response": completedResponse])
        let lines = events.map { event in
            let payload = String(decoding: json(event), as: UTF8.self)
            return "event: \(event["type"] as? String ?? "message")\ndata: \(payload)\n\n"
        }.joined()
        return Data((lines + "data: [DONE]\n\n").utf8)
    }

    public static func nonStreaming(id: String = "resp_\(UUID().uuidString.lowercased())", model: String, text: String) -> Data {
        json([
            "id": id,
            "object": "response",
            "status": "completed",
            "model": model,
            "output_text": text,
            "output": [[
                "id": "msg_\(id)",
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [["type": "output_text", "text": text, "annotations": []]]
            ]]
        ])
    }
}

/// Disjuntor local para falhas de cota e respostas vazias. A classe é segura
/// para as filas concorrentes do servidor e é deliberadamente determinística.
public final class CodexCircuitBreaker: @unchecked Sendable {
    public let threshold: Int
    public let failureWindow: TimeInterval
    public let cooldown: TimeInterval
    private let lock = NSLock()
    private let clock: @Sendable () -> Date
    private let stateURL: URL?
    private var failures: [Date] = []
    private var openedAt: Date?

    public init(threshold: Int = 3, failureWindow: TimeInterval = 600, cooldown: TimeInterval = 900, stateURL: URL? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.threshold = threshold; self.failureWindow = failureWindow; self.cooldown = cooldown; self.stateURL = stateURL; self.clock = clock
    }

    public func check() -> String? {
        lock.lock(); defer { lock.unlock() }
        return withStateLock {
            let now = clock()
            loadPersistentState()
            if let openedAt, now.timeIntervalSince(openedAt) < cooldown { return "disjuntor aberto após falhas de cota; tente novamente mais tarde" }
            if let openedAt, now.timeIntervalSince(openedAt) >= cooldown { self.openedAt = nil; failures.removeAll() }
            failures = failures.filter { now.timeIntervalSince($0) <= failureWindow }
            persistState()
            return failures.count >= threshold ? "disjuntor aberto após falhas de cota; tente novamente mais tarde" : nil
        }
    }

    public func recordFailure() { lock.lock(); defer { lock.unlock() }; withStateLock { loadPersistentState(); let now = clock(); failures = failures.filter { now.timeIntervalSince($0) <= failureWindow }; failures.append(now); if failures.count >= threshold { openedAt = now }; persistState() } }
    public func recordSuccess() { lock.lock(); defer { lock.unlock() }; withStateLock { failures.removeAll(); openedAt = nil; persistState() } }

    private func loadPersistentState() {
        guard let stateURL, let data = FileManager.default.contents(atPath: stateURL.path(percentEncoded: false)), let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        failures = state.failures.map(Date.init(timeIntervalSince1970:)); openedAt = state.openedAt.map(Date.init(timeIntervalSince1970:))
    }

    private func persistState() {
        guard let stateURL else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let state = State(failures: failures.map(\.timeIntervalSince1970), openedAt: openedAt?.timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        guard let stateURL else { return body() }
        let lockURL = stateURL.appendingPathExtension("lock")
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path(percentEncoded: false), O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return body() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return body() }
        defer { flock(descriptor, LOCK_UN) }
        return body()
    }

    private struct State: Codable { var failures: [TimeInterval]; var openedAt: TimeInterval? }
}

public enum CodexFailureClassification {
    public static func isQuota(exitCode: Int32, stderr: String, status: String? = nil) -> Bool {
        exitCode == 3 || status?.uppercased().contains("AGY_ERROR") == true || stderr.uppercased().contains("AGY_ERROR") || stderr.localizedCaseInsensitiveContains("quota") || stderr.localizedCaseInsensitiveContains("rate limit")
    }
}

/// Limita chamadas também entre processos sem depender de um lock em memória.
public final class CodexConcurrencyGate: @unchecked Sendable {
    public struct Lease: Sendable, Hashable {
        fileprivate let path: String
    }

    private let directory: URL
    private let maximum: Int
    private var ownedSlots: Set<String> = []
    private let lock = NSLock()
    public init(directory: URL, maximum: Int = 2) { self.directory = directory; self.maximum = maximum }

    public func acquire() -> Lease? {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<maximum {
            let path = directory.appending(path: "slot-\(index).lock").path(percentEncoded: false)
            let handle = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            if handle >= 0 {
                _ = "\(getpid())".data(using: .utf8).flatMap { data in data.withUnsafeBytes { write(handle, $0.baseAddress, data.count) } }
                ownedSlots.insert(path); close(handle); return Lease(path: path)
            }
            if let data = FileManager.default.contents(atPath: path), let pid = Int32(String(decoding: data, as: UTF8.self)), pid > 0, kill(pid, 0) != 0, errno == ESRCH {
                try? FileManager.default.removeItem(atPath: path)
                let retry = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
                if retry >= 0 {
                    _ = "\(getpid())".data(using: .utf8).flatMap { data in data.withUnsafeBytes { write(retry, $0.baseAddress, data.count) } }
                    ownedSlots.insert(path); close(retry); return Lease(path: path)
                }
            }
        }
        return nil
    }

    public func release(_ lease: Lease) {
        lock.lock(); defer { lock.unlock() }
        guard ownedSlots.remove(lease.path) != nil else { return }
        try? FileManager.default.removeItem(atPath: lease.path)
    }
}

/// Invoca o `agy` já autenticado e converte seu envelope em texto Responses.
public struct CodexAgyInvoker: Sendable {
    public let executable: URL
    public let environment: [String: String]
    public let timeout: Duration
    public let responseBudget: Int
    public init(
        executable: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration = .seconds(900),
        responseBudget: Int = DelegationRequest.maximumResponseBudget
    ) {
        self.executable = executable
        self.environment = environment
        self.timeout = timeout
        self.responseBudget = max(1, min(responseBudget, DelegationRequest.maximumResponseBudget))
    }

    public func invoke(_ request: CodexResponsesRequest, role: CodexRole, processRunner: any ProcessRunning = SubprocessRunner()) throws -> AgyEnvelope {
        let workspace = request.workingDirectory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue else { throw AgyAgentError.processLaunchFailed(executable: executable.path, reason: "workspace inexistente") }
        let home = environment["HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        if Workspace(root: workspace, isRepository: false).isUnsafeBroadDirectory(homeDirectory: home) {
            throw AgyAgentError.processLaunchFailed(executable: executable.path, reason: "home ou raiz do sistema não pode ser anexada")
        }
        var arguments = ["--output-format", "stream-json", "--input-format", "stream-json", "--disable-slash-commands", "--model", role.model, "--agent", role.agent, "--mode", role.mode, "--add-dir", workspace.path(percentEncoded: false), "--print-timeout", "\(timeout.components.seconds)s"]
        if role.sandboxed { arguments.append("--sandbox") }
        let inputObject: [String: Any] = ["event": "user", "message": ["role": "user", "content": request.prompt]]
        let inputData = (try? JSONSerialization.data(withJSONObject: inputObject)) ?? Data()
        var processEnvironment = environment
        processEnvironment["NO_COLOR"] = "1"; processEnvironment["TERM"] = "dumb"; processEnvironment["CLICOLOR"] = "0"
        let result = try processRunner.run(ProcessPlan(executable: executable, arguments: arguments, workingDirectory: workspace, environment: processEnvironment, timeout: timeout + .seconds(15), standardInput: String(decoding: inputData, as: UTF8.self) + "\n"))
        var envelope: AgyEnvelope
        do { envelope = try AgyEnvelope.decode(fromStreamOutput: result.standardOutput) } catch { throw CodexFailureClassification.isQuota(exitCode: result.exitCode, stderr: result.standardError) ? AgyAgentError.agyFailed(status: "QUOTA", output: result.standardError) : error }
        guard envelope.status.isSuccess else { throw AgyAgentError.agyFailed(status: envelope.status.rawValue, output: result.standardError) }
        guard !envelope.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgyAgentError.emptyResponse(result.standardError) }
        envelope.response = ResponseBudget.apply(responseBudget, to: envelope.response).text
        return envelope
    }

}

/// Servidor HTTP mínimo, sem dependência externa. Ele aceita somente loopback
/// e o endpoint Responses usado pelo provider customizado do Codex.
public final class CodexProxyServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 47321
    public typealias Handler = @Sendable (Data) -> (status: Int, contentType: String, body: Data)
    private let port: UInt16
    private let pathToken: String
    private let handler: Handler
    private let maximumBodyBytes: Int

    public init(port: UInt16 = CodexProxyServer.defaultPort, pathToken: String, maximumBodyBytes: Int = 2_000_000, handler: @escaping Handler) {
        self.port = port; self.pathToken = pathToken; self.maximumBodyBytes = maximumBodyBytes; self.handler = handler
    }

    public func serve() throws -> Never {
        #if canImport(Darwin)
        let server = socket(AF_INET, SOCK_STREAM, 0)
        guard server >= 0 else { throw AgyAgentError.processLaunchFailed(executable: "socket", reason: String(cString: strerror(errno))) }
        defer { close(server) }
        var reuse: Int32 = 1
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw AgyAgentError.processLaunchFailed(executable: "bind", reason: String(cString: strerror(errno))) }
        guard listen(server, 8) == 0 else { throw AgyAgentError.processLaunchFailed(executable: "listen", reason: String(cString: strerror(errno))) }
        while true {
            let client = accept(server, nil, nil)
            if client < 0 { continue }
            var receiveTimeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global(qos: .userInitiated).async { [handler, maximumBodyBytes, pathToken, port] in
                Self.handle(client: client, port: port, pathToken: pathToken, handler: handler, maximumBodyBytes: maximumBodyBytes)
            }
        }
        #else
        throw AgyAgentError.processLaunchFailed(executable: "socket", reason: "sockets indisponíveis nesta plataforma")
        #endif
    }

    #if canImport(Darwin)
    private static func handle(client: Int32, port: UInt16, pathToken: String, handler: Handler, maximumBodyBytes: Int) {
        defer { close(client) }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var headerEnd: Range<Data.Index>?
        var expectedBody = 0
        while bytes.count <= maximumBodyBytes + 32_000 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            bytes.append(buffer, count: count)
            if headerEnd == nil, let range = bytes.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range
                let header = String(decoding: bytes[..<range.lowerBound], as: UTF8.self)
                expectedBody = header.split(separator: "\r\n").dropFirst().compactMap { line in
                    let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return parts.count == 2 && parts[0].caseInsensitiveCompare("Content-Length") == .orderedSame ? Int(parts[1]) : nil
                }.first ?? 0
                if expectedBody < 0 || expectedBody > maximumBodyBytes { write(client: client, status: 413, type: "application/json", body: Data(#"{"error":{"message":"request body too large"}}"#.utf8)); return }
            }
            if let range = headerEnd, bytes.count >= range.upperBound + expectedBody { break }
        }
        guard let range = headerEnd, bytes.count >= range.upperBound + expectedBody else { write(client: client, status: 400, type: "application/json", body: Data(#"{"error":{"message":"invalid HTTP request"}}"#.utf8)); return }
        let header = String(decoding: bytes[..<range.lowerBound], as: UTF8.self)
        let first = header.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        guard accepts(headers: header, port: port) else {
            write(client: client, status: 400, type: "application/json", body: Data(#"{"error":{"message":"invalid HTTP headers"}}"#.utf8))
            return
        }
        if first.hasPrefix("GET /health ") {
            write(client: client, status: 200, type: "application/json", body: Data(#"{"ok":true,"service":"agy-agent"}"#.utf8))
            return
        }
        guard accepts(requestLine: first, pathToken: pathToken) else { write(client: client, status: 404, type: "application/json", body: Data(#"{"error":{"message":"not found"}}"#.utf8)); return }
        let body = Data(bytes[range.upperBound..<(range.upperBound + expectedBody)])
        let response = handler(body)
        write(client: client, status: response.status, type: response.contentType, body: response.body)
    }

    public static func accepts(requestLine: String, pathToken: String) -> Bool {
        guard pathToken.count == 64 else { return false }
        return requestLine.hasPrefix("POST /\(pathToken)/v1/responses ")
    }

    /// Restringe o endpoint a clientes HTTP locais comuns. Validar Host evita
    /// DNS rebinding; recusar Origin impede que páginas web usem o serviço;
    /// este servidor não implementa corpos chunked.
    public static func accepts(headers text: String, port: UInt16) -> Bool {
        let requestLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        var headers: [String: String] = [:]
        for line in text.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return false }
            headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let expectedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = headers["host"], expectedHosts.contains(host.lowercased()) else { return false }
        guard headers["origin"] == nil else { return false }
        guard headers["transfer-encoding"] == nil else { return false }
        if requestLine.hasPrefix("POST ") {
            guard let type = headers["content-type"], type.lowercased().hasPrefix("application/json") else { return false }
        }
        return true
    }

    private static func write(client: Int32, status: Int, type: String, body: Data) {
        let reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : status == 413 ? "Payload Too Large" : status == 429 ? "Too Many Requests" : "Error"
        let prefix = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var output = Data(prefix.utf8); output.append(body)
        output.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var sent = 0
            while sent < output.count {
                let count = send(client, base.advanced(by: sent), output.count - sent, 0)
                if count <= 0 { break }
                sent += count
            }
        }
    }
    #endif
}
