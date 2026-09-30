import Foundation

/// Material extra entregue junto com a pergunta.
///
/// A distinção entre os dois casos é a decisão mais importante da ferramenta
/// para economia de contexto. Se o chamador precisar colar um diff ou um
/// arquivo no comando, ele já pagou por aquele texto no próprio contexto — a
/// delegação passa a custar mais do que economiza. `.file` referencia o
/// caminho e deixa o `agy` ler do disco; nada do conteúdo passa pelo chamador.
/// Nome prefixado para não colidir com `Testing.Attachment`.
public enum DelegationAttachment: Sendable, Equatable {
    /// Texto que só existe em memória do chamador.
    case inline(String)
    /// Arquivo em disco, referenciado por caminho.
    case file(path: String, contentDigest: String)

    /// Entra na chave de cache. Para arquivo, o digest é do conteúdo: o mesmo
    /// caminho com conteúdo diferente precisa de uma entrada diferente.
    public var digest: String {
        switch self {
        case .inline(let text): Digest.sha256(text)
        case .file(let path, let contentDigest): Digest.sha256("\(path)\u{1F}\(contentDigest)")
        }
    }

    var isEmpty: Bool {
        switch self {
        case .inline(let text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file(let path, _): path.isEmpty
        }
    }
}

/// Pedido de delegação, já com o prompt de sistema resolvido.
///
/// O prompt chega pronto em vez de ser carregado aqui: manter o runner
/// independente da configuração permite testá-lo sem tocar em `~/.config`.
public struct DelegationRequest: Sendable, Equatable {
    /// Limite absoluto do texto que uma delegação pode devolver ao chamador.
    /// Os padrões por modo são menores; este teto impede que um override
    /// acidental transforme uma chamada MCP em uma resposta sem controle.
    public static let maximumResponseBudget = 8_000

    public var mode: Mode
    public var question: String
    public var model: String
    public var systemPrompt: String
    public var attachment: DelegationAttachment?
    public var workspace: Workspace?
    public var timeout: Duration
    /// Diretório usado quando o modo não anexa workspace.
    public var neutralDirectory: URL
    /// `--sandbox`: bloqueia rede e acesso a arquivos fora do workspace.
    /// Não impede escrita dentro dele — ver `Mode.usesSandbox`.
    public var sandboxed: Bool
    /// Limite de caracteres da resposta.
    public var responseBudget: Int
    /// Conversa do `agy` a retomar (`--conversation`). O histórico já está do
    /// lado do Gemini: a pergunta de acompanhamento não reenvia contexto.
    public var conversationID: String?

    public init(
        mode: Mode,
        question: String,
        model: String? = nil,
        systemPrompt: String,
        attachment: DelegationAttachment? = nil,
        workspace: Workspace? = nil,
        timeout: Duration? = nil,
        neutralDirectory: URL,
        sandboxed: Bool? = nil,
        responseBudget: Int? = nil,
        conversationID: String? = nil
    ) {
        self.mode = mode
        self.question = question
        self.model = model ?? mode.defaultModel
        self.systemPrompt = systemPrompt
        self.attachment = attachment
        self.workspace = workspace
        self.timeout = timeout ?? mode.defaultTimeout
        self.neutralDirectory = DirectoryURL.normalized(neutralDirectory)
        self.sandboxed = sandboxed ?? mode.usesSandbox
        self.responseBudget = responseBudget ?? mode.responseBudget
        self.conversationID = conversationID
    }

    /// Identificador aceito para `--conversation`: só o formato que o `agy`
    /// emite (UUID em hexadecimal com hífens). Impede que um valor com traço
    /// no início seja lido como outra opção.
    public static func isValidConversationID(_ value: String) -> Bool {
        value.count >= 8 && value.count <= 64
            && value.allSatisfy { $0.isHexDigit || $0 == "-" }
            && !value.hasPrefix("-")
    }

    public static func isValidModel(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && !value.hasPrefix("-")
            && value.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-._/:".unicodeScalars.contains($0))
            }
    }

    public func validated() throws -> DelegationRequest {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgyAgentError.emptyQuestion
        }
        if let conversationID, !Self.isValidConversationID(conversationID) {
            throw AgyAgentError.invalidConversationID(conversationID)
        }
        guard Self.isValidModel(model) else {
            throw AgyAgentError.invalidConfiguration("identificador de modelo inválido")
        }
        guard responseBudget > 0, responseBudget <= Self.maximumResponseBudget else {
            throw AgyAgentError.invalidResponseBudget(
                requested: responseBudget,
                maximum: Self.maximumResponseBudget
            )
        }
        if mode.requiresWorkspace, workspace == nil {
            throw AgyAgentError.workspaceRequired(mode)
        }
        return self
    }

    /// Consulta correspondente, para cache e proveniência.
    public var query: Query {
        Query(
            mode: mode,
            question: question,
            model: model,
            workspaceRoot: workspace.map(\.rootPath),
            promptDigest: Digest.sha256("\(systemPrompt)\u{1F}budget=\(responseBudget)"),
            attachmentDigest: attachment.map(\.digest)
        )
    }
}

/// Montagem determinística da linha de comando do `agy`.
///
/// Toda a lógica é pura: a ordem e o formato dos argumentos são exatamente o
/// que se quer fixar em teste, porque é onde o `agy` tem armadilhas.
public enum AgyInvocation {
    /// Instrução de orçamento, anexada a todo prompt.
    ///
    /// O limite é pedido ao modelo **e** aplicado na volta: pedir não é
    /// garantir, e o texto excedente custaria contexto de quem chamou.
    public static func budgetInstruction(_ characters: Int) -> String {
        """
        ## Formato da resposta

        Responda em no máximo \(characters) caracteres. Sem preâmbulo, sem
        repetir a pergunta, sem resumo final. Vá direto à conclusão e à
        evidência que a sustenta. Se a resposta completa não couber, entregue
        a conclusão e a evidência mais forte, e diga o que ficou de fora.

        Não use links markdown. Cite referências em texto puro — `arquivo:linha`
        para código, URL nua apenas para fontes da web. Cada link gasta
        orçamento sem acrescentar informação.
        """
    }

    /// Texto único entregue ao `agy`.
    ///
    /// O anexo inline vai delimitado por marcadores para que o modelo não
    /// confunda material citado com instrução.
    public static func composePrompt(_ request: DelegationRequest) -> String {
        var parts = [request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)]
        parts.append(budgetInstruction(request.responseBudget))
        parts.append("## Pergunta\n\n" + request.question.trimmingCharacters(in: .whitespacesAndNewlines))

        if let attachment = request.attachment, !attachment.isEmpty {
            switch attachment {
            case .inline(let text):
                parts.append("## Material fornecido\n\n<<<AGY-AGENT-ANEXO\n\(text)\nAGY-AGENT-ANEXO")
            case .file(let path, _):
                parts.append("## Material fornecido\n\nLeia o arquivo `\(path)`. O conteúdo não foi colado aqui de propósito.")
            }
        }
        if let workspace = request.workspace, request.mode.requiresWorkspace {
            parts.append("## Workspace\n\n\(workspace.rootPath)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Diretórios que o `agy` precisa enxergar.
    ///
    /// O anexo por caminho só é legível se o diretório que o contém estiver
    /// no workspace da sessão.
    public static func additionalDirectories(for request: DelegationRequest) -> [String] {
        var directories: [String] = []
        if let workspace = request.workspace, request.mode.requiresWorkspace {
            directories.append(workspace.rootPath)
        }
        if case .file(let path, _) = request.attachment {
            let parent = DirectoryURL.path(
                URL(filePath: path, directoryHint: .notDirectory).deletingLastPathComponent()
            )
            if !directories.contains(parent) { directories.append(parent) }
        }
        return directories
    }

    /// Argumentos do `agy`, sem o caminho do executável.
    ///
    /// O prompt viaja pelo stdin em stream-json. Além de preservar quebras e
    /// metacaracteres sem interpretação pelo shell, isso impede que conteúdo
    /// potencialmente sensível apareça em `ps` ou em relatórios de processo.
    public static func arguments(for request: DelegationRequest) -> [String] {
        var arguments = [
            "--model", request.model,
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--disable-slash-commands",
            "--print-timeout", "\(request.timeout.components.seconds)s",
        ]
        for directory in additionalDirectories(for: request) {
            arguments += ["--add-dir", directory]
        }
        if request.sandboxed {
            arguments.append("--sandbox")
        }
        if let conversationID = request.conversationID {
            arguments += ["--conversation", conversationID]
        }
        return arguments
    }

    /// Evento aceito pelo modo `--input-format stream-json` do agy.
    public static func standardInput(for request: DelegationRequest) -> String {
        let object: [String: Any] = [
            "event": "user",
            "message": ["role": "user", "content": composePrompt(request)]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            preconditionFailure("evento de entrada fixo deve ser JSON válido")
        }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Diretório de trabalho do processo.
    ///
    /// Modos sem workspace rodam em diretório neutro: arquivos de contexto do
    /// projeto onde o comando foi digitado não devem influenciar uma pergunta
    /// que não é sobre aquele projeto.
    public static func workingDirectory(for request: DelegationRequest) -> URL {
        if request.mode.requiresWorkspace, let workspace = request.workspace {
            return workspace.root
        }
        return request.neutralDirectory
    }

    /// Ambiente do processo.
    ///
    /// Cor e capacidades de terminal são desligadas: sequências ANSI no stdout
    /// corromperiam a decodificação do envelope JSON.
    public static func environment(inheriting parent: [String: String]) -> [String: String] {
        var environment = parent
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        environment["CLICOLOR"] = "0"
        return environment
    }

    /// Margem entre o timeout pedido ao `agy` e a terminação forçada.
    ///
    /// Um processo que trave antes de instalar o próprio temporizador não
    /// seria coberto por `--print-timeout`.
    public static let terminationGrace: Duration = .seconds(15)

    public static func plan(for request: DelegationRequest, executable: URL, parentEnvironment: [String: String]) -> ProcessPlan {
        ProcessPlan(
            executable: executable,
            arguments: arguments(for: request),
            workingDirectory: workingDirectory(for: request),
            environment: environment(inheriting: parentEnvironment),
            timeout: request.timeout + terminationGrace,
            standardInput: standardInput(for: request)
        )
    }
}
