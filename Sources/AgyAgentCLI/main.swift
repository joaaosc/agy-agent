import Foundation
import AgyAgentKit

let environment = ProcessInfo.processInfo.environment
let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
let paths = Paths.resolve(environment: environment, homeDirectory: home)
let arguments = CommandRouting.arguments(for: CommandLine.arguments)
let prompts = PromptLibrary(directory: paths.promptsDirectory)

let configuration: Configuration = {
    do {
        return try Configuration.load(from: paths.configFile)
    } catch {
        FileHandle.standardError.write(Data("agy-agent: \(error)\n".utf8))
        exit(78)
    }
}()

func emit(_ line: String = "") { print(line) }

/// Tudo que não é a resposta vai para stderr: stdout é o que custa contexto
/// de quem chamou.
func note(_ line: String) {
    FileHandle.standardError.write(Data("\(line)\n".utf8))
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("agy-agent: \(message)\n".utf8))
    exit(code)
}

func printUsage() {
    emit("""
    agy-agent \(ToolInfo.version) — estado: \(ToolInfo.isActive ? "ativo" : "INATIVO (em construção)")

    Uso:
      agy-agent paths              Mostra os caminhos resolvidos (não cria diretórios)
      agy-agent modes              Lista os modos e seus padrões
      agy-agent locate             Mostra qual executável agy seria usado
      agy-agent plan <modo> <texto>  Imprime a linha de comando que seria executada
      agy-agent config             Mostra a configuração efetiva por modo
      agy-agent stats              Mostra o que os bancos já registraram
      agy-agent promote <chave>    Move um pacote do cache para o banco durável
      agy-agent report [--detalhado]  Gasto da janela e o que a delegação poupou
      agy-agent usage              Três linhas de uso das janelas ativas
      agy-agent watch [segundos]      O mesmo painel, atualizando sozinho
      agy-agent install            Cria o link em ~/.local/bin (--with-usage-alias é opcional)
      agy-agent codex-enable      Instala o provider Responses local e o MCP externo
      agy-agent codex-disable     Remove apenas os artefatos gerenciados do provider
      agy-agent codex-status      Verifica provider, proxy, MCP e executável
      agy-agent panel               Abre a aba do kitty com o painel ao vivo
      agy-agent metrics [--erros|--latencia]  Tentativas, falhas e latência externa
      agy-agent doctor              Verifica runtime, modelos, limites e registro MCP
      agy-agent mcp-enable          Registra e ativa o servidor MCP
      agy-agent mcp-disable         Remove o registro MCP sem apagar dados
      agy-agent mcp-serve           Servidor MCP stdio opcional
      agy-agent codex-proxy         Servidor Responses loopback (uso pelo LaunchAgent)
      agy-agent codex-delegate      Executor interno dos jobs externos
      agy-agent version            Mostra a versão

    Delegação (só a resposta vai para stdout):
      agy-agent research  <pergunta>   Pesquisa na web, com fontes
      agy-agent inspect   <pergunta>   Lê o repositório corrente
      agy-agent verify    <afirmação>  Confirma, refuta ou diz inconclusivo
      agy-agent summarize <pergunta>   Condensa material fornecido

    Opções de delegação:
      --model M      --timeout S     --budget N
      --file CAMINHO (anexo por referência; o conteúdo não é colado)
      --conversation ID   retoma uma conversa (o ID sai na linha "conversa" do
                          stderr); o histórico fica no Gemini, sem cache
      --refresh      --no-cache      --json      --quiet

    A pergunta também pode vir por stdin. Só a resposta vai para stdout.
    """)
}

// MARK: - MCP stdio

/// Transporte MCP mínimo, deliberadamente mantido no executável CLI.
///
/// Uma única ferramenta representa o ciclo de vida inteiro do job. Assim o
/// chamador pode iniciar até duas delegações, acompanhar e cancelar cada uma
/// sem manter uma chamada MCP bloqueada e sem pagar por quatro definições de
/// ferramenta em toda sessão.
func runMCPServer() {
    func send(_ value: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let line = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    func errorResponse(id: Any, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    func objectText(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return #"{"error":"falha ao serializar estado"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    let currentDirectory = URL(
        filePath: FileManager.default.currentDirectoryPath,
        directoryHint: .isDirectory
    )
    guard let serverExecutable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        note("agy-agent: servidor MCP indisponível: executável atual não resolvido")
        return
    }
    let jobs: MCPJobManager
    do {
        try paths.createWritableDirectories()
        jobs = try MCPJobManager(
            executable: serverExecutable,
            workingDirectory: currentDirectory,
            outputDirectory: paths.stateDirectory.appending(path: "mcp-jobs"),
            environment: environment,
            maxConcurrentJobs: 2
        )
    } catch {
        note("agy-agent: servidor MCP indisponível: \(error)")
        return
    }

    func snapshotText(_ snapshot: MCPJobManager.Snapshot) -> String {
        objectText([
            "job_id": snapshot.id,
            "mode": snapshot.label,
            "state": snapshot.state.rawValue,
            "elapsed_seconds": Int(snapshot.elapsedSeconds.rounded(.down))
        ])
    }

    func spawn(_ arguments: [String: Any]) -> (text: String, isError: Bool) {
        if let roleName = arguments["codex_role"] as? String {
            guard let role = CodexRole(rawValue: roleName) else {
                return ("codex_role deve ser gemini_worker, gemini_explorer ou gemini_reviewer", true)
            }
            guard let question = arguments["question"] as? String,
                  !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ("question é obrigatória", true)
            }
            do {
                let options = try CodexDelegateOptions(
                    role: role,
                    timeoutSeconds: arguments["timeout"] as? Int ?? CodexDelegateOptions.maximumTimeoutSeconds,
                    responseBudget: arguments["budget"] as? Int ?? DelegationRequest.maximumResponseBudget
                )
                return (
                    snapshotText(try jobs.spawn(
                        arguments: options.childArguments,
                        label: role.rawValue,
                        stdin: Data(question.utf8)
                    )),
                    false
                )
            } catch {
                return ("\(error)", true)
            }
        }
        guard let modeName = arguments["mode"] as? String,
              let mode = Mode(rawValue: modeName) else {
            return ("mode deve ser research, inspect, verify ou summarize", true)
        }
        guard let question = arguments["question"] as? String,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("question é obrigatória", true)
        }

        var childArguments = [mode.rawValue, "--json", "--quiet"]
        if let timeout = arguments["timeout"] as? Int {
            guard (1...900).contains(timeout) else {
                return ("timeout deve ficar entre 1 e 900 segundos", true)
            }
            childArguments += ["--timeout", String(timeout)]
        }
        if let budget = arguments["budget"] as? Int {
            guard (1...DelegationRequest.maximumResponseBudget).contains(budget) else {
                return ("budget deve ficar entre 1 e \(DelegationRequest.maximumResponseBudget) caracteres", true)
            }
            childArguments += ["--budget", String(budget)]
        }
        if let file = arguments["file"] as? String, !file.isEmpty {
            guard let attachment = MCPAttachmentPolicy.resolve(file, within: currentDirectory) else {
                return ("file deve apontar para um arquivo regular dentro do diretório onde o MCP foi iniciado", true)
            }
            childArguments += ["--file", attachment.path(percentEncoded: false)]
        }
        if arguments["refresh"] as? Bool == true { childArguments.append("--refresh") }
        if arguments["no_cache"] as? Bool == true { childArguments.append("--no-cache") }
        do {
            return (snapshotText(try jobs.spawn(arguments: childArguments, label: mode.rawValue, stdin: Data(question.utf8))), false)
        } catch {
            return ("\(error)", true)
        }
    }

    func callTool(_ arguments: [String: Any]) -> (text: String, isError: Bool) {
        guard let action = arguments["action"] as? String else {
            return ("action é obrigatória", true)
        }
        if action == "spawn" { return spawn(arguments) }

        guard let id = arguments["job_id"] as? String, !id.isEmpty else {
            return ("job_id é obrigatório para \(action)", true)
        }
        do {
            switch action {
            case "status":
                return (snapshotText(try jobs.status(id: id)), false)
            case "cancel":
                return (snapshotText(try jobs.cancel(id: id)), false)
            case "result", "wait":
                if action == "wait" {
                    // O transporte stdio é sequencial. Um long-poll extenso
                    // impediria ping e cancelamento; um segundo mantém a
                    // ferramenta responsiva e o chamador pode repetir wait.
                    let deadline = Date().addingTimeInterval(1)
                    while Date() < deadline, try jobs.status(id: id).state == .running {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
                switch try jobs.collect(id: id) {
                case .running(let snapshot):
                    return (snapshotText(snapshot), false)
                case .cancelled(let snapshot):
                    return (snapshotText(snapshot), false)
                case .failed(_, let detail):
                    return (detail.isEmpty ? "delegação falhou sem diagnóstico" : detail, true)
                case .completed(_, let output):
                    if let packet = try? JSONDecoder().decode(EvidencePacket.self, from: output) {
                        return (packet.response, false)
                    }
                    let response = String(decoding: output, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return response.isEmpty
                        ? ("resposta do job vazia", true)
                        : (response, false)
                }
            default:
                return ("action deve ser spawn, status, wait, result ou cancel", true)
            }
        } catch {
            return ("\(error)", true)
        }
    }

    let toolDescription = "Gerencia delegações externas com resposta limitada. O servidor deve ter sido iniciado dentro do projeto, nunca no diretório home. Use action=spawn com codex_role e question, defina timeout para limitar a duração e depois repita action=wait com job_id até receber a resposta final. Cada wait aguarda no máximo um segundo. Há no máximo 2 jobs simultâneos. A alternativa mode mantém os modos research, inspect, verify e summarize."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["spawn", "status", "wait", "result", "cancel"]],
            "job_id": ["type": "string"],
            "codex_role": ["type": "string", "enum": CodexRole.allCases.map(\.rawValue)],
            "mode": ["type": "string", "enum": Mode.allCases.map(\.rawValue)],
            "question": ["type": "string"],
            "timeout": ["type": "integer", "minimum": 1, "maximum": CodexDelegateOptions.maximumTimeoutSeconds],
            "budget": ["type": "integer", "minimum": 1, "maximum": DelegationRequest.maximumResponseBudget],
            "file": ["type": "string"],
            "refresh": ["type": "boolean"],
            "no_cache": ["type": "boolean"]
        ],
        "required": ["action"]
    ]

    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        guard let method = request["method"] as? String else { continue }
        let id = request["id"]

        if method.hasPrefix("notifications/") {
            continue
        }
        guard let id else { continue }

        switch method {
        case "initialize":
            send(["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "agy-agent", "version": ToolInfo.version]
            ]])
        case "ping":
            send(["jsonrpc": "2.0", "id": id, "result": [:]])
        case "tools/list":
            send(["jsonrpc": "2.0", "id": id, "result": ["tools": [[
                "name": "agy_job",
                "description": toolDescription,
                "inputSchema": inputSchema
            ]]]])
        case "tools/call":
            guard let params = request["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                errorResponse(id: id, code: -32602, message: "params.name é obrigatório")
                continue
            }
            guard name == "agy_job" else {
                errorResponse(id: id, code: -32601, message: "ferramenta desconhecida: \(name)")
                continue
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let result = callTool(arguments)
            send(["jsonrpc": "2.0", "id": id, "result": [
                "content": [["type": "text", "text": result.text]],
                "isError": result.isError
            ]])
        default:
            errorResponse(id: id, code: -32601, message: "método desconhecido: \(method)")
        }
    }
}

func printPaths() {
    let override = environment["AGY_AGENT_HOME"].map { " (AGY_AGENT_HOME=\($0))" } ?? ""
    emit("Caminhos resolvidos\(override):")
    emit("  config      \(paths.configDirectory.path(percentEncoded: false))")
    emit("  prompts     \(paths.promptsDirectory.path(percentEncoded: false))")
    emit("  config.toml \(paths.configFile.path(percentEncoded: false))")
    emit("  data        \(paths.dataDirectory.path(percentEncoded: false))")
    emit("  state       \(paths.stateDirectory.path(percentEncoded: false))")
    emit("  knowledge   \(paths.knowledgeDatabase.path(percentEncoded: false))")
    emit("  cache       \(paths.cacheDirectory.path(percentEncoded: false))")
    emit("  cache.db    \(paths.cacheDatabase.path(percentEncoded: false))")
    emit("  logs        \(paths.logFile.path(percentEncoded: false))")
    emit()
    emit("Nenhum diretório foi criado por este comando.")
}

func printModes() {
    emit("modo        modelo padrão            workspace  web    sandbox  timeout")
    for mode in Mode.allCases {
        let name = mode.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)
        let model = mode.defaultModel.padding(toLength: 24, withPad: " ", startingAt: 0)
        let workspace = (mode.requiresWorkspace ? "sim" : "não").padding(toLength: 10, withPad: " ", startingAt: 0)
        let web = (mode.dependsOnWebSearch ? "sim" : "não").padding(toLength: 6, withPad: " ", startingAt: 0)
        let sandbox = (mode.usesSandbox ? "sim" : "não").padding(toLength: 8, withPad: " ", startingAt: 0)
        emit("\(name) \(model) \(workspace) \(web) \(sandbox) \(mode.defaultTimeout.components.seconds)s")
    }
}

func printConfig() {
    let exists = FileManager.default.fileExists(atPath: paths.configFile.path(percentEncoded: false))
    emit("config.toml: \(exists ? paths.configFile.path(percentEncoded: false) : "ausente — usando padrões")")
    if let agyPath = configuration.agyPath {
        emit("agy_path:    \(agyPath)")
    }
    emit()
    for mode in Mode.allCases {
        let settings = configuration.settings(for: mode)
        emit("[\(mode.rawValue)]")
        emit("  modelo          \(settings.model)")
        emit("  timeout         \(settings.timeout.components.seconds)s")
        emit("  orçamento       \(settings.responseBudget) caracteres")
        emit("  idade do cache  \(settings.maxCacheAge.components.seconds)s\(mode.dependsOnWebSearch ? "" : "  (ignorada: modo não depende da web)")")
        emit("  sandbox         \(settings.sandboxed ? "sim" : "não")")
        emit("  prompt          \(prompts.origin(for: mode))")
    }
}

func locateAgy() -> AgyLocator.Source {
    do {
        return try AgyLocator().locate(environment: environment, homeDirectory: home)
    } catch {
        fail("\(error)")
    }
}

func printLocate() {
    let source = locateAgy()
    let origin = switch source {
    case .explicit: "caminho explícito"
    case .environment: "AGY_BIN"
    case .path: "PATH"
    case .fallback: "~/.local/bin"
    }
    emit("agy: \(source.url.path(percentEncoded: false))  (via \(origin))")
    emit()
    emit("A função de shell agy() não é usada: o binário é invocado diretamente.")
}

func printPlan(_ rest: [String]) {
    guard rest.count >= 2, let mode = Mode(rawValue: rest[0]) else {
        fail("uso: agy-agent plan <\(Mode.allCases.map(\.rawValue).joined(separator: "|"))> <pergunta>", code: 64)
    }
    let question = rest.dropFirst().joined(separator: " ")

    let workspace = Workspace.resolve(
        startingAt: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
        homeDirectory: home,
        exists: { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    )
    if mode.requiresWorkspace, workspace.isUnsafeBroadDirectory(homeDirectory: home) {
        fail("home ou raiz do sistema não pode ser anexada; entre em um projeto ou subdiretório", code: 64)
    }

    let settings = configuration.settings(for: mode)
    let systemPrompt: String
    do {
        systemPrompt = try prompts.prompt(for: mode)
    } catch {
        fail("\(error)", code: 78)
    }

    let request = DelegationRequest(
        mode: mode,
        question: question,
        model: settings.model,
        systemPrompt: systemPrompt,
        workspace: mode.requiresWorkspace ? workspace : nil,
        timeout: settings.timeout,
        neutralDirectory: paths.stateDirectory,
        sandboxed: settings.sandboxed,
        responseBudget: settings.responseBudget
    )

    do {
        _ = try request.validated()
    } catch {
        fail("\(error)", code: 65)
    }

    let plan = AgyInvocation.plan(
        for: request,
        executable: locateAgy().url,
        parentEnvironment: environment
    )

    emit("Simulação — nada será executado.")
    emit()
    emit("executável  \(plan.executable.path(percentEncoded: false))")
    emit("diretório   \(plan.workingDirectory.path(percentEncoded: false))")
    emit("workspace   \(workspace.rootPath)\(workspace.isRepository ? "" : "  (sem marcador de raiz)")")
    emit("timeout     \(request.timeout.components.seconds)s + \(AgyInvocation.terminationGrace.components.seconds)s de margem")
    emit("orçamento   \(request.responseBudget) caracteres")
    emit("prompt      \(prompts.origin(for: mode))")
    emit("chave       \(request.query.cacheKey)")
    emit()
    emit("argumentos:")
    for argument in plan.arguments { emit("  \(argument)") }
    emit("stdin       <evento stream-json com \(AgyInvocation.composePrompt(request).count) caracteres de prompt>")
}

func printStats() {
    // Ler não deve criar banco: uma ferramenta inativa não semeia arquivos.
    let bases = [("cache", paths.cacheDatabase), ("knowledge", paths.knowledgeDatabase)]
    var anyExists = false

    for (name, url) in bases {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            emit("\(name): ainda não existe")
            continue
        }
        anyExists = true
        do {
            let statistics = try PacketStore(url: url).statistics()
            emit("\(name):")
            emit("  pacotes                  \(statistics.packets)")
            emit("  usos servidos do cache   \(statistics.hits)")
            emit("  caracteres armazenados   \(statistics.responseCharacters)")
            emit("  caracteres poupados      \(statistics.charactersServedFromCache)  (medida exata)")
            emit("  ~tokens poupados aqui    \(statistics.estimatedCallerTokensSaved)  (estimativa: 4 caracteres por token)")
            emit("  respostas cortadas       \(statistics.truncated)")
            emit("  tokens gastos no agy     \(statistics.agyTokens)  (não custam contexto do chamador)")
            emit("  saída gerada no agy      \(statistics.agyOutputTokens)  (turno inteiro, não só a resposta)")
            emit("  saída evitada no agy     \(statistics.agyOutputTokensAvoided)  (chamadas que o cache dispensou)")
        } catch {
            emit("\(name): \(error)")
        }
    }

    if !anyExists {
        emit()
        emit("Nenhuma chamada foi registrada ainda — a ferramenta está inativa.")
    }
}

func delegationStore() -> PacketStore? {
    do {
        return try PacketStore(url: paths.cacheDatabase)
    } catch {
        note("agy-agent: cache indisponível (\(error)); seguindo sem ele")
        return nil
    }
}

func runDelegation(_ mode: Mode, _ rest: [String]) {
    let parsed: DelegationArguments
    do {
        parsed = try DelegationArguments.parse(
            mode: mode,
            arguments: rest,
            readStandardInput: {
                isatty(FileHandle.standardInput.fileDescriptor) == 1
                    ? nil
                    : String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            }
        )
    } catch {
        fail("\(error)", code: 64)
    }

    do {
        try paths.createWritableDirectories()
    } catch {
        fail("\(error)", code: 73)
    }

    let settings = configuration.settings(for: mode)
    let executable = locateAgy().url

    let workspace = Workspace.resolve(
        startingAt: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
        homeDirectory: home,
        exists: { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    )
    if mode.requiresWorkspace, workspace.isUnsafeBroadDirectory(homeDirectory: home) {
        fail("home ou raiz do sistema não pode ser anexada; entre em um projeto ou subdiretório", code: 64)
    }

    do {
        // A primeira delegação materializa os prompts no disco, para o usuário
        // poder editá-los. Depois disso o arquivo local é a fonte da verdade.
        try prompts.seedMissing()
    } catch {
        note("agy-agent: prompts não semeados (\(error)); usando os embutidos")
    }

    let request: DelegationRequest
    do {
        request = DelegationRequest(
            mode: mode,
            question: parsed.question,
            model: parsed.model ?? settings.model,
            systemPrompt: try prompts.prompt(for: mode),
            attachment: try parsed.attachment(),
            workspace: mode.requiresWorkspace ? workspace : nil,
            timeout: parsed.timeoutSeconds.map { .seconds($0) } ?? settings.timeout,
            neutralDirectory: paths.stateDirectory,
            sandboxed: settings.sandboxed,
            responseBudget: parsed.responseBudget ?? settings.responseBudget,
            conversationID: parsed.conversationID
        )
    } catch {
        fail("\(error)", code: 78)
    }

    // O freio precisa do histórico mesmo quando a chamada não vai usar cache:
    // ignorar o gasto já feito é justamente o que se quer evitar.
    let store = delegationStore()
    let service = DelegationService(
        runner: AgyRunner(
            executable: executable,
            agyVersion: AgyRunner.readVersion(executable: executable, workingDirectory: paths.stateDirectory)
        ),
        cache: store,
        spendGuard: SpendGuard(limits: configuration.limits),
        telemetry: telemetryStore()
    )

    do {
        let outcome = try service.delegate(
            request,
            maxCacheAge: settings.maxCacheAge,
            policy: parsed.cachePolicy
        )
        for warning in outcome.warnings { note("agy-agent: \(warning)") }

        if parsed.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            emit(String(decoding: try encoder.encode(outcome.packet), as: UTF8.self))
        } else {
            emit(outcome.packet.response)
        }

        if !parsed.quiet {
            let packet = outcome.packet
            let cost = outcome.origin == .cache
                ? "sem custo"
                : "\(packet.usage.totalTokens) tokens no agy, \(String(format: "%.1f", packet.durationSeconds))s"
            note("agy-agent: \(outcome.origin.label) · \(packet.responseCharacters) caracteres · \(cost)")
            note("agy-agent: chave \(packet.cacheKey)")
            if let conversationID = packet.conversationID {
                note("agy-agent: conversa \(conversationID)")
            }
            if packet.truncated {
                note("agy-agent: resposta cortada no orçamento de \(request.responseBudget) caracteres")
            }
        }
    } catch {
        fail("\(error)", code: 70)
    }
}

/// Janela padrão de uso dos agentes.
let defaultWindow: Duration = .seconds(5 * 3600)

func buildReport() -> SavingsReport {
    let end = Date()
    let fallbackStart = end.addingTimeInterval(-Double(defaultWindow.components.seconds))
    let window = UsageWindow(homeDirectory: home).consumption(from: fallbackStart, to: end)
    let start = window.activeRateLimitWindowStart ?? fallbackStart
    let delegation = delegationSummary(since: start)

    return SavingsReport(window: window, delegation: delegation, windowLength: defaultWindow)
}

func delegationSummary(since start: Date) -> SavingsReport.Delegation {
    var delegation = SavingsReport.Delegation()
    for url in [paths.cacheDatabase, paths.knowledgeDatabase]
    where FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
        if let store = try? PacketStore(url: url), let summary = try? store.delegationSummary(since: start) {
            delegation = SavingsReport.Delegation(
                calls: delegation.calls + summary.calls,
                cacheHits: delegation.cacheHits + summary.cacheHits,
                responseCharacters: delegation.responseCharacters + summary.responseCharacters,
                charactersFromCache: delegation.charactersFromCache + summary.charactersFromCache,
                agyInputTokens: delegation.agyInputTokens + summary.agyInputTokens,
                agyOutputTokens: delegation.agyOutputTokens + summary.agyOutputTokens
            )
        }
    }
    if let telemetry = telemetryStore(), let summary = try? telemetry.externalUsageSummary(since: start) {
        delegation = delegation.adding(SavingsReport.Delegation(
            calls: summary.successfulCalls,
            responseCharacters: summary.responseCharacters,
            agyInputTokens: summary.inputTokens,
            agyOutputTokens: summary.outputTokens
        ))
    }
    return delegation
}

func externalSpendVerdict(at now: Date = Date()) -> SpendGuard.Verdict {
    let start = now.addingTimeInterval(-Double(configuration.limits.window.components.seconds))
    let summary = delegationSummary(since: start)
    return SpendGuard(limits: configuration.limits).check(
        callsUsed: summary.calls,
        tokensUsed: summary.externalTokens
    )
}

func callerBreakdown(since: Date) -> [Caller: Int] {
    guard FileManager.default.fileExists(atPath: paths.cacheDatabase.path(percentEncoded: false)),
          let store = try? PacketStore(url: paths.cacheDatabase),
          let callers = try? store.callsByCaller(since: since) else { return [:] }
    return callers
}

func renderPanel(detailed: Bool) -> String {
    let report = buildReport()
    return detailed
        ? SavingsRenderer.render(report)
        : SavingsRenderer.renderCompact(
            report,
            callers: callerBreakdown(since: report.activeRateLimitWindowStart ?? report.window.start),
            limits: configuration.limits
        )
}

func printReport(_ rest: [String]) {
    emit(renderPanel(detailed: rest.contains("--detalhado")))
}

func printUsageStatus() {
    let end = Date()
    let fallbackStart = end.addingTimeInterval(-Double(defaultWindow.components.seconds))
    let window = UsageWindow(homeDirectory: home).consumption(from: fallbackStart, to: end)
    let externalTokens = delegationSummary(since: fallbackStart).externalTokens
    emit(UsageRenderer.render(
        window: window,
        externalTokens: externalTokens,
        maxExternalTokens: configuration.limits.maxAgyTokens,
        now: end
    ))
}

/// Atualiza o relatório no lugar, sem falar com modelo nenhum.
///
/// Custa zero token: lê o SQLite local e os transcritos que Claude Code e
/// Codex já gravam. Rodar isto num segundo terminal enquanto se trabalha é
/// observação pura — o gasto está na sessão do agente, não em quem a observa.
func watch(_ rest: [String]) {
    let interval = rest.first.flatMap(Int.init).map { max(2, $0) } ?? 10
    note("agy-agent: atualizando a cada \(interval)s. Ctrl-C encerra. Custo: zero tokens.")
    while true {
        // Limpa a tela e volta ao topo, sem depender de curses.
        emit("\u{1B}[2J\u{1B}[H")
        emit(renderPanel(detailed: rest.contains("--detalhado")))
        emit("")
        emit("  atualizado \(SavingsRenderer.time(Date())) · intervalo \(interval)s · Ctrl-C encerra")
        Thread.sleep(forTimeInterval: Double(interval))
    }
}

func install(_ rest: [String]) {
    let installer = Installer(paths: paths, homeDirectory: home)

    if rest.contains("--uninstall") {
        do {
            let removed = try installer.uninstall()
            emit(removed ? "link removido: \(installer.linkURL.path(percentEncoded: false))" : "nada a remover")
            emit("Configuração, prompts e bancos foram mantidos.")
        } catch {
            fail("\(error)", code: 73)
        }
        return
    }

    let explicit = rest.first { !$0.hasPrefix("--") }.map { URL(filePath: $0, directoryHint: .notDirectory) }
    guard let runningExecutable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        fail("executável atual não pôde ser resolvido", code: 69)
    }
    // O README inicia este comando pelo produto de release retornado pelo
    // SwiftPM. Usar o executável corrente evita depender do layout interno
    // de `.build`, que varia entre toolchains.
    let target = explicit ?? runningExecutable

    do {
        let installUsageAlias = rest.contains("--with-usage-alias")
        let report = try installer.install(
            executable: target,
            environment: environment,
            installUsageAlias: installUsageAlias
        )
        emit("link      \(report.linkPath)")
        emit("aponta    \(report.target)")
        emit("estado    \(report.created ? "criado" : report.replaced ? "substituído" : "já estava correto")")
        if installUsageAlias { emit("alias     \(report.usageLinkPath)") }
        if !report.seededPrompts.isEmpty {
            emit("prompts   \(report.seededPrompts.map(\.rawValue).joined(separator: ", ")) copiados para \(paths.promptsDirectory.path(percentEncoded: false))")
        }
        if report.wroteConfigTemplate {
            emit("config    modelo escrito em \(paths.configFile.path(percentEncoded: false))")
        }
        emit("")
        if !report.pathContainsLinkDirectory {
            emit("ATENÇÃO: ~/.local/bin não está no PATH. Acrescente ao ~/.zshrc:")
            emit("  export PATH=\"$HOME/.local/bin:$PATH\"")
            emit("")
        }
        emit("Para o Claude Code chamar sem pedir permissão a cada vez,")
        emit("acrescente a ~/.claude/settings.json, em permissions.allow:")
        emit("  \"Bash(agy-agent:*)\"")
        emit("")
        emit("A integração MCP é opcional porque sua definição entra no contexto")
        emit("de toda sessão. Ative com `agy-agent mcp-enable` e remova sem")
        emit("apagar dados com `agy-agent mcp-disable`.")
    } catch {
        fail("\(error)", code: 73)
    }
}

func codexInstaller() -> CodexInstaller { CodexInstaller(homeDirectory: home) }

func codexEnable(_ rest: [String]) {
    let installer = codexInstaller()
    guard let runningExecutable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        fail("executável atual não pôde ser resolvido", code: 69)
    }
    let source = rest.first.map { URL(filePath: $0, directoryHint: .notDirectory) } ?? runningExecutable
    do {
        let installed = try installer.enable(sourceExecutable: source)
        emit("Codex provider ativado")
        for path in installed { emit("  \(path)") }
        emit("base URL  \(installer.displayBaseURL)")
        emit("reinicie o Codex para carregar o provider e o MCP")
    } catch { fail("\(error)", code: 73) }
}

func codexDisable() {
    do { try codexInstaller().disable(); emit("Codex provider desativado; dados do usuário foram mantidos") }
    catch { fail("\(error)", code: 73) }
}

func codexStatus() {
    let installer = codexInstaller()
    let status = installer.status()
    emit("provider    \(status.provider ? "OK" : "ausente")")
    emit("MCP         \(status.mcp ? "OK" : "ausente")")
    let loaded = installer.launchAgentIsLoaded()
    emit("LaunchAgent \(status.launchAgent && loaded ? "OK" : "ausente/não carregado")")
    emit("endpoint    \(codexProxyIsLive() ? "OK" : "inativo")")
    emit("executável  \(status.executable ? "OK" : "ausente") · \(installer.installedExecutable.path)")
    emit("despachantes internos \(status.agents.isEmpty ? "ausentes (correto; use agy_job diretamente)" : "presentes: \(status.agents.joined(separator: ", "))")")
}

func codexProxyIsLive() -> Bool {
    let curl = URL(filePath: "/usr/bin/curl", directoryHint: .notDirectory)
    guard FileManager.default.isExecutableFile(atPath: curl.path) else { return false }
    let result = try? SubprocessRunner().run(ProcessPlan(
        executable: curl,
        arguments: ["--fail", "--silent", "--show-error", "--max-time", "1", codexInstaller().healthURL],
        workingDirectory: home,
        environment: ["PATH": "/usr/bin:/bin"],
        timeout: .seconds(2)
    ))
    return result?.exitCode == 0
}

func runCodexProxy() {
    let fallback = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let port = UInt16(environment["AGY_CODEX_PORT"] ?? "") ?? CodexProxyServer.defaultPort
    let breaker = CodexCircuitBreaker(stateURL: paths.stateDirectory.appending(path: "codex-circuit.json"))
    let gate = CodexConcurrencyGate(directory: paths.stateDirectory.appending(path: "codex-gates"), maximum: 2)
    let source: URL
    do { source = try AgyLocator().locate(environment: environment, homeDirectory: home).url }
    catch { fail("provider indisponível: \(error)", code: 69) }
    let invoker = CodexAgyInvoker(executable: source, environment: environment)
    let pathToken: String
    do { pathToken = try codexInstaller().providerToken() }
    catch { fail("provider sem token protegido: \(error)", code: 78) }
    let server = CodexProxyServer(port: port, pathToken: pathToken) { body in
        do {
            let request = try CodexResponsesRequest(data: body, fallbackDirectory: fallback)
            if case .blocked(let reason) = externalSpendVerdict() {
                let response = request.streaming
                    ? CodexResponses.stream(model: request.model, text: "", error: reason)
                    : CodexResponses.json(["error": ["message": reason, "type": "rate_limit_error"]])
                return (429, request.streaming ? "text/event-stream" : "application/json", response)
            }
            if let reason = breaker.check() { return (429, "text/event-stream", CodexResponses.stream(model: request.model, text: "", error: reason)) }
            guard let lease = gate.acquire() else { return (429, "application/json", CodexResponses.json(["error": ["message": "limite de duas delegações simultâneas atingido", "type": "rate_limit_error"]])) }
            defer { gate.release(lease) }
            let role = CodexRole.resolve(model: request.model)
            let startedAt = Date()
            do {
                let envelope = try invoker.invoke(request, role: role)
                recordCodexUsage(role: role, startedAt: startedAt, envelope: envelope, success: true)
                breaker.recordSuccess()
                let body = request.streaming ? CodexResponses.stream(model: request.model, text: envelope.response) : CodexResponses.nonStreaming(model: request.model, text: envelope.response)
                return (200, request.streaming ? "text/event-stream" : "application/json", body)
            } catch {
                recordCodexUsage(role: role, startedAt: startedAt, envelope: nil, success: false)
                let detail = "\(error)"
                if detail.localizedCaseInsensitiveContains("quota") || detail.localizedCaseInsensitiveContains("agy_error") || detail.localizedCaseInsensitiveContains("empty response") { breaker.recordFailure() }
                let response = request.streaming ? CodexResponses.stream(model: request.model, text: "", error: detail) : CodexResponses.json(["error": ["message": detail, "type": "server_error"]])
                return (502, request.streaming ? "text/event-stream" : "application/json", response)
            }
        } catch {
            return (400, "application/json", CodexResponses.json(["error": ["message": "\(error)", "type": "invalid_request_error"]]))
        }
    }
    do { try server.serve() } catch { fail("proxy indisponível: \(error)", code: 69) }
}

func executable(named name: String) -> URL? {
    for component in (environment["PATH"] ?? "").split(separator: ":") {
        let candidate = URL(filePath: String(component), directoryHint: .isDirectory)
            .appending(path: name)
        if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) {
            return candidate
        }
    }
    return nil
}

func runCodexMCP(_ arguments: [String]) throws -> ProcessResult {
    guard let codex = executable(named: "codex") else {
        throw AgyAgentError.processLaunchFailed(executable: "codex", reason: "não encontrado no PATH")
    }
    return try SubprocessRunner().run(ProcessPlan(
        executable: codex,
        arguments: ["mcp"] + arguments,
        workingDirectory: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
        environment: AgyInvocation.environment(inheriting: environment),
        timeout: .seconds(30)
    ))
}

func setMCPEnabled(_ enabled: Bool) {
    let name = "agy-agent"
    do {
        let current = try runCodexMCP(["get", name])
        if enabled {
            let link = home.appending(path: ".local/bin/agy-agent")
            guard FileManager.default.isExecutableFile(atPath: link.path(percentEncoded: false)) else {
                fail("instale primeiro com `agy-agent install`", code: 69)
            }
            let expected = "command: \(link.path(percentEncoded: false))"
            if current.exitCode == 0, current.standardOutput.contains(expected) {
                emit("MCP já está ativo: \(link.path(percentEncoded: false))")
                emit("Uma sessão já aberta precisa ser reiniciada para carregar a ferramenta.")
                return
            }
            if current.exitCode == 0 {
                let removed = try runCodexMCP(["remove", name])
                guard removed.exitCode == 0 else {
                    fail(removed.standardError.isEmpty ? removed.standardOutput : removed.standardError, code: 70)
                }
            }
            let added = try runCodexMCP(["add", name, "--", link.path(percentEncoded: false), "mcp-serve"])
            guard added.exitCode == 0 else {
                fail(added.standardError.isEmpty ? added.standardOutput : added.standardError, code: 70)
            }
            emit("MCP ativado: \(link.path(percentEncoded: false)) mcp-serve")
            emit("Reinicie a sessão do cliente para carregar `agy_job`.")
        } else {
            guard current.exitCode == 0 else {
                emit("MCP já está desativado; configuração e histórico foram mantidos.")
                return
            }
            let removed = try runCodexMCP(["remove", name])
            guard removed.exitCode == 0 else {
                fail(removed.standardError.isEmpty ? removed.standardOutput : removed.standardError, code: 70)
            }
            emit("MCP desativado; configuração, cache e histórico foram mantidos.")
            emit("Uma sessão já aberta pode manter a ferramenta até ser reiniciada.")
        }
    } catch {
        fail("\(error)", code: 70)
    }
}

func doctor() {
    var failures = 0
    func result(_ ok: Bool, _ label: String, _ detail: String) {
        emit("\(ok ? "OK" : "FALHA")  \(label): \(detail)")
        if !ok { failures += 1 }
    }

    do {
        try paths.createWritableDirectories()
    } catch {
        result(false, "diretórios", "\(error)")
    }

    let link = home.appending(path: ".local/bin/agy-agent")
    result(
        FileManager.default.isExecutableFile(atPath: link.path(percentEncoded: false)),
        "CLI",
        link.path(percentEncoded: false)
    )

    do {
        let source = try AgyLocator().locate(environment: environment, homeDirectory: home)
        let version = AgyRunner.readVersion(
            executable: source.url,
            workingDirectory: paths.stateDirectory,
            environment: environment
        )
        result(version != "unknown", "runtime", "\(source.url.path(percentEncoded: false)) · \(version)")

        let models = try SubprocessRunner().run(ProcessPlan(
            executable: source.url,
            arguments: ["models"],
            workingDirectory: paths.stateDirectory,
            environment: AgyInvocation.environment(inheriting: environment),
            timeout: .seconds(30)
        ))
        let configured = Set(Mode.allCases.map { configuration.settings(for: $0).model })
        let missing = configured.filter { !models.standardOutput.contains("\($0)\t") }.sorted()
        result(models.exitCode == 0 && missing.isEmpty, "modelos", missing.isEmpty ? "\(configured.count) configurados e disponíveis" : "ausentes: \(missing.joined(separator: ", "))")
    } catch {
        result(false, "runtime", "\(error)")
    }

    let invalidBudgets = Mode.allCases.filter {
        let value = configuration.settings(for: $0).responseBudget
        return value <= 0 || value > DelegationRequest.maximumResponseBudget
    }
    result(
        invalidBudgets.isEmpty,
        "orçamentos",
        invalidBudgets.isEmpty
            ? "todos até \(DelegationRequest.maximumResponseBudget) caracteres"
            : "fora do limite: \(invalidBudgets.map(\.rawValue).joined(separator: ", "))"
    )

    let codex = codexInstaller().status()
    var externalMCPRegistered = false
    do {
        let registration = try runCodexMCP(["get", "agy-agent"])
        externalMCPRegistered = registration.exitCode == 0
    } catch {}
    if externalMCPRegistered || codex.mcp {
        result(true, "MCP", "registrado; reinicie sessões antigas para carregar")
    } else {
        emit("OPCIONAL  MCP: desativado")
    }

    if codex.provider || codex.launchAgent || codex.executable {
        result(codex.provider, "Codex provider", codex.provider ? "Responses em loopback com caminho autenticado" : "configuração incompleta")
        let loaded = codexInstaller().launchAgentIsLoaded()
        let live = codexProxyIsLive()
        result(codex.launchAgent && loaded && live, "Codex proxy", codex.launchAgent && loaded && live ? "LaunchAgent carregado e endpoint vivo" : "plist/carregamento/endpoint ausente")
    } else {
        emit("OPCIONAL  Codex provider: desativado")
        emit("OPCIONAL  Codex proxy: desativado")
    }
    result(codex.agents.isEmpty, "despachantes internos", codex.agents.isEmpty ? "ausentes; agy_job chama o executor externo diretamente" : "remova: \(codex.agents.joined(separator: ", "))")

    emit("")
    if failures == 0 {
        emit("Diagnóstico concluído sem falhas. Nenhuma chamada de modelo foi feita.")
    } else {
        fail("diagnóstico encontrou \(failures) falha(s)", code: 1)
    }
}

func runCodexDelegation(_ rest: [String]) {
    let options: CodexDelegateOptions
    do { options = try CodexDelegateOptions.parse(rest) }
    catch { fail("\(error)", code: 64) }
    let role = options.role
    let question: String
    if options.questionParts.isEmpty {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard data.count <= MCPJobManager.maximumInputBytes else {
            fail("tarefa excede o limite de \(MCPJobManager.maximumInputBytes) bytes", code: 64)
        }
        guard !data.contains(0) else { fail("tarefa contém U+0000", code: 64) }
        question = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        question = options.questionParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !question.isEmpty else { fail("tarefa vazia", code: 64) }
    if case .blocked(let reason) = externalSpendVerdict() { fail(reason, code: 75) }
    let breaker = CodexCircuitBreaker(stateURL: paths.stateDirectory.appending(path: "codex-circuit.json"))
    if let reason = breaker.check() { fail(reason, code: 75) }
    let gate = CodexConcurrencyGate(directory: paths.stateDirectory.appending(path: "codex-gates"), maximum: 2)
    guard let lease = gate.acquire() else { fail("limite de duas delegações simultâneas atingido", code: 75) }
    defer { gate.release(lease) }
    let startedAt = Date()
    do {
        let agy = try AgyLocator().locate(environment: environment, homeDirectory: home).url
        let request = CodexResponsesRequest(
            model: role.rawValue,
            prompt: question,
            workingDirectory: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
            streaming: false
        )
        let envelope = try CodexAgyInvoker(
            executable: agy,
            environment: environment,
            timeout: .seconds(options.timeoutSeconds),
            responseBudget: options.responseBudget
        ).invoke(request, role: role)
        guard !envelope.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            recordCodexUsage(role: role, startedAt: startedAt, envelope: envelope, success: false)
            breaker.recordFailure()
            fail("delegação retornou resposta vazia", code: 70)
        }
        recordCodexUsage(role: role, startedAt: startedAt, envelope: envelope, success: true)
        breaker.recordSuccess()
        emit(envelope.response)
    } catch {
        recordCodexUsage(role: role, startedAt: startedAt, envelope: nil, success: false)
        let detail = "\(error)"
        if detail.localizedCaseInsensitiveContains("quota")
            || detail.localizedCaseInsensitiveContains("agy_error")
            || detail.localizedCaseInsensitiveContains("empty response") {
            breaker.recordFailure()
        }
        fail("\(error)", code: 70)
    }
}

func telemetryStore() -> TelemetryStore? {
    guard FileManager.default.fileExists(atPath: paths.telemetryDatabase.path(percentEncoded: false))
        || (try? paths.createWritableDirectories()) != nil else { return nil }
    return try? TelemetryStore(url: paths.telemetryDatabase)
}

/// Registra somente contadores do executor externo; prompt, resposta e cwd
/// nunca atravessam esta fronteira de telemetria.
func recordCodexUsage(role: CodexRole, startedAt: Date, envelope: AgyEnvelope?, success: Bool) {
    guard let telemetry = telemetryStore() else { return }
    let record = TelemetryStore.ExternalUsageRecord(
        timestamp: startedAt,
        role: role.rawValue,
        inputTokens: envelope?.usage.inputTokens ?? 0,
        outputTokens: envelope?.usage.outputTokens ?? 0,
        durationSeconds: Date().timeIntervalSince(startedAt),
        backendDurationSeconds: envelope?.durationSeconds,
        numTurns: envelope?.numTurns ?? 0,
        responseCharacters: envelope?.response.count ?? 0,
        success: success
    )
    try? telemetry.recordExternalUsage(record)
}

func runPanel() {
    // Silencioso de propósito: chamado por um wrapper de shell antes de
    // claude/codex começarem, e nunca deve atrasar ou poluir aquele início.
    let panel = KittyPanel()
    let agyAgentLink = home.appending(path: ".local/bin/agy-agent").path(percentEncoded: false)
    let availability = panel.ensureOpen(
        environment: environment,
        workingDirectory: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
        panelCommand: [agyAgentLink, "watch", "15"]
    )
    switch availability {
    case .opened: note("agy-agent: aba do painel aberta")
    case .alreadyOpen: break
    case .unavailable(let reason): note("agy-agent: painel não aberto (\(reason))")
    case .failed(let reason): note("agy-agent: falha ao abrir o painel (\(reason))")
    }
}

func printMetrics(_ rest: [String]) {
    guard let telemetry = telemetryStore() else {
        emit("Nenhuma tentativa registrada ainda.")
        return
    }
    if rest.contains("--erros") || rest.contains("--errors") {
        printRecentFailures(telemetry)
        return
    }
    if rest.contains("--latencia") || rest.contains("--latency") {
        printExternalLatency(telemetry)
        return
    }
    do {
        let summary = try telemetry.summary()
        emit("MÉTRICAS — histórico completo")
        emit("")
        emit("tentativas totais  \(summary.total)")
        for outcome in AttemptRecord.Outcome.allCases {
            let count = summary.byOutcome[outcome] ?? 0
            guard count > 0 else { continue }
            let percent = summary.total > 0 ? String(format: "%.0f%%", Double(count) * 100 / Double(summary.total)) : "0%"
            emit("  \(outcome.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(count)  (\(percent))")
        }
        emit("")
        emit("por modo")
        for mode in Mode.allCases {
            guard let count = summary.byMode[mode] else { continue }
            emit("  \(mode.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(count)")
        }
        if !summary.errorsByKind.isEmpty {
            emit("")
            emit("erros por tipo")
            for (kind, count) in summary.errorsByKind.sorted(by: { $0.value > $1.value }) {
                emit("  \(kind.padding(toLength: 22, withPad: " ", startingAt: 0)) \(count)")
            }
        }
        if let average = summary.averageDurationSeconds {
            emit("")
            emit("duração média das chamadas reais  \(String(format: "%.1f", average))s")
        }
        emit("")
        emit("Detalhe dos erros recentes: agy-agent metrics --erros")
    } catch {
        fail("\(error)", code: 70)
    }
}

func printExternalLatency(_ telemetry: TelemetryStore) {
    do {
        let records = try telemetry.recentExternalLatency()
        guard !records.isEmpty else {
            emit("Nenhum job externo registrado ainda.")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM HH:mm"
        emit("LATÊNCIA — jobs externos recentes")
        emit("parede inclui inicialização; turnos são de conversa, não chamadas de ferramenta")
        emit("")
        for record in records {
            let wall = record.durationSeconds.map { String(format: "%.1fs", $0) } ?? "?"
            let backend = record.backendDurationSeconds.map { String(format: "%.1fs", $0) } ?? "?"
            let turns = record.numTurns > 0 ? String(record.numTurns) : "?"
            let outcome = record.success ? "OK" : "FALHA"
            emit("\(formatter.string(from: record.timestamp))  \(record.role)  \(outcome)")
            emit("  parede \(wall) · backend \(backend) · turnos conversa \(turns) · tokens \(record.totalTokens)")
        }
    } catch {
        fail("\(error)", code: 70)
    }
}

func printRecentFailures(_ telemetry: TelemetryStore) {
    do {
        let failures = try telemetry.recentFailures()
        guard !failures.isEmpty else {
            emit("Nenhum erro ou bloqueio registrado.")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM HH:mm"
        for failure in failures {
            emit("\(formatter.string(from: failure.timestamp))  \(failure.mode.rawValue)  \(failure.caller.label)  \(failure.errorKind ?? "?")")
            if let detail = failure.errorDetail, !detail.isEmpty {
                emit("  \(detail)")
            }
        }
    } catch {
        fail("\(error)", code: 70)
    }
}

func promote(_ rest: [String]) {
    guard let key = rest.first, !key.isEmpty else {
        fail("uso: agy-agent promote <chave>", code: 64)
    }
    do {
        let cache = try PacketStore(url: paths.cacheDatabase)
        let knowledge = try PacketStore(url: paths.knowledgeDatabase)
        let packet = try cache.promote(key: key, to: knowledge)
        note("agy-agent: promovido \(packet.query.mode.rawValue) · \(packet.responseCharacters) caracteres")
        note("agy-agent: \(knowledge.url.path(percentEncoded: false))")
    } catch {
        fail("\(error)", code: 70)
    }
}

switch arguments.first {
case "paths":
    printPaths()
case "modes":
    printModes()
case "locate":
    printLocate()
case "plan":
    printPlan(Array(arguments.dropFirst()))
case "config":
    printConfig()
case "stats":
    printStats()
case "promote":
    promote(Array(arguments.dropFirst()))
case "report":
    printReport(Array(arguments.dropFirst()))
case "usage":
    printUsageStatus()
case "watch":
    watch(Array(arguments.dropFirst()))
case "install":
    install(Array(arguments.dropFirst()))
case "codex-enable":
    codexEnable(Array(arguments.dropFirst()))
case "codex-disable":
    codexDisable()
case "codex-status":
    codexStatus()
case "panel":
    runPanel()
case "metrics":
    printMetrics(Array(arguments.dropFirst()))
case "doctor":
    doctor()
case "mcp-enable":
    setMCPEnabled(true)
case "mcp-disable":
    setMCPEnabled(false)
case "mcp-serve":
    runMCPServer()
case "codex-proxy":
    runCodexProxy()
case "codex-delegate":
    runCodexDelegation(Array(arguments.dropFirst()))
case let name? where Mode(rawValue: name) != nil:
    runDelegation(Mode(rawValue: name)!, Array(arguments.dropFirst()))
case "version", "--version":
    emit(ToolInfo.version)
case nil, "help", "--help", "-h":
    printUsage()
default:
    FileHandle.standardError.write(Data("agy-agent: subcomando desconhecido: \(arguments[0])\n".utf8))
    printUsage()
    exit(64)
}
