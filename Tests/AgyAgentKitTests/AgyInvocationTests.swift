import Testing
import Foundation
@testable import AgyAgentKit

@Suite("Montagem da linha de comando do agy")
struct AgyInvocationTests {
    static let neutral = URL(filePath: "/Users/tester/Library/Application Support/agy-agent/state", directoryHint: .isDirectory)
    static let repo = Workspace(root: URL(filePath: "/Users/tester/Repo", directoryHint: .isDirectory), isRepository: true)

    static func request(
        mode: Mode = .verify,
        question: String = "A API X existe no SDK do macOS 27?",
        model: String? = nil,
        systemPrompt: String = "Responda com evidência.",
        attachment: DelegationAttachment? = nil,
        workspace: Workspace? = nil,
        sandboxed: Bool? = nil
    ) -> DelegationRequest {
        DelegationRequest(
            mode: mode,
            question: question,
            model: model,
            systemPrompt: systemPrompt,
            attachment: attachment,
            workspace: workspace,
            neutralDirectory: neutral,
            sandboxed: sandboxed
        )
    }

    @Test("O prompt vai pelo stdin e não aparece nos argumentos")
    func promptUsesStandardInput() {
        let request = Self.request(question: "segredo de teste")
        let arguments = AgyInvocation.arguments(for: request)
        #expect(!arguments.contains { $0.contains("segredo de teste") })
        #expect(!arguments.contains { $0 == "--print" || $0.hasPrefix("--print=") })
        #expect(AgyInvocation.standardInput(for: request).contains("segredo de teste"))
    }

    @Test("Formato JSON e desativação de comandos são sempre pedidos")
    func fixedFlags() {
        let arguments = AgyInvocation.arguments(for: Self.request())
        let pairs = zip(arguments, arguments.dropFirst())
        #expect(pairs.contains { $0 == "--output-format" && $1 == "stream-json" })
        #expect(pairs.contains { $0 == "--input-format" && $1 == "stream-json" })
        #expect(arguments.contains("--disable-slash-commands"))
    }

    @Test("Uma pergunta iniciada por / não é expandida como comando")
    func slashQuestionIsSafe() {
        let arguments = AgyInvocation.arguments(for: Self.request(question: "/compact isso é uma pergunta?"))
        #expect(arguments.contains("--disable-slash-commands"))
        #expect(!arguments.contains { $0.contains("/compact isso é uma pergunta?") })
        #expect(AgyInvocation.standardInput(for: Self.request(question: "/compact isso é uma pergunta?")).contains("/compact isso é uma pergunta?"))
    }

    @Test("O modelo padrão vem do modo e pode ser sobrescrito")
    func modelSelection() {
        let byMode = AgyInvocation.arguments(for: Self.request(mode: .summarize))
        #expect(byMode.contains(Mode.summarize.defaultModel))
        let overridden = AgyInvocation.arguments(for: Self.request(model: "gemini-3.1-pro-high"))
        #expect(overridden.contains("gemini-3.1-pro-high"))
        #expect(!overridden.contains(Mode.verify.defaultModel))
    }

    @Test("--print-timeout usa o limite do pedido, em segundos")
    func printTimeout() {
        let arguments = AgyInvocation.arguments(for: Self.request(mode: .research))
        let pairs = zip(arguments, arguments.dropFirst())
        #expect(pairs.contains { $0 == "--print-timeout" && $1 == "300s" })
    }

    @Test("A terminação forçada acontece depois do timeout pedido ao agy")
    func planTimeoutHasGrace() {
        let request = Self.request(mode: .research)
        let plan = AgyInvocation.plan(
            for: request,
            executable: URL(filePath: "/bin/agy", directoryHint: .notDirectory),
            parentEnvironment: [:]
        )
        #expect(plan.timeout.components.seconds > request.timeout.components.seconds)
        #expect(plan.timeout == request.timeout + AgyInvocation.terminationGrace)
    }

    @Test("--add-dir só aparece nos modos que exigem workspace")
    func addDirOnlyForWorkspaceModes() {
        let inspect = AgyInvocation.arguments(for: Self.request(mode: .inspect, workspace: Self.repo))
        let pairs = zip(inspect, inspect.dropFirst())
        #expect(pairs.contains { $0 == "--add-dir" && $1 == "/Users/tester/Repo" })

        // Um workspace informado num modo que não o exige é ignorado como
        // argumento: research não deve anexar o repositório.
        let research = AgyInvocation.arguments(for: Self.request(mode: .research, workspace: Self.repo))
        #expect(!research.contains("--add-dir"))
    }

    @Test("--dangerously-skip-permissions nunca é passado")
    func neverSkipsPermissions() {
        // Verificado empiricamente: em --print o agy executa ferramentas sem
        // pedir aprovação de qualquer modo. A flag só ampliaria o alcance.
        for mode in Mode.allCases {
            let workspace = mode.requiresWorkspace ? Self.repo : nil
            let arguments = AgyInvocation.arguments(for: Self.request(mode: mode, workspace: workspace))
            #expect(!arguments.contains("--dangerously-skip-permissions"))
        }
    }

    @Test("--mode plan nunca é passado")
    func neverUsesPlanMode() {
        // Verificado: plan mode é ignorado junto com --disable-slash-commands
        // e, mesmo sozinho, não impediu escrita. Custa mais tokens e produz
        // texto de aprovação interativa que não faz sentido em --print.
        for mode in Mode.allCases {
            let workspace = mode.requiresWorkspace ? Self.repo : nil
            #expect(!AgyInvocation.arguments(for: Self.request(mode: mode, workspace: workspace)).contains("--mode"))
        }
    }

    @Test("--sandbox fica ligado só no modo que anexa repositório e não usa web")
    func sandboxConfinesInspect() {
        #expect(AgyInvocation.arguments(for: Self.request(mode: .inspect, workspace: Self.repo)).contains("--sandbox"))
        for mode in Mode.allCases where mode != .inspect {
            #expect(!AgyInvocation.arguments(for: Self.request(mode: mode)).contains("--sandbox"))
        }
        // Sandbox bloqueia rede; ligá-lo em research inutilizaria o modo.
        #expect(!Mode.research.usesSandbox)
        #expect(!Mode.verify.usesSandbox)
    }

    @Test("Modos com workspace rodam na raiz; os demais, em diretório neutro")
    func workingDirectory() {
        #expect(AgyInvocation.workingDirectory(for: Self.request(mode: .inspect, workspace: Self.repo)) == Self.repo.root)
        #expect(AgyInvocation.workingDirectory(for: Self.request(mode: .research, workspace: Self.repo)) == DirectoryURL.normalized(Self.neutral))
    }

    @Test("Cor e capacidades de terminal são desligadas")
    func environmentIsPlain() {
        let environment = AgyInvocation.environment(inheriting: ["TERM": "xterm-256color", "HOME": "/Users/tester"])
        #expect(environment["NO_COLOR"] == "1")
        #expect(environment["TERM"] == "dumb")
        #expect(environment["CLICOLOR"] == "0")
        #expect(environment["HOME"] == "/Users/tester")
    }

    @Test("O anexo inline é delimitado para não se confundir com instrução")
    func inlineAttachmentIsDelimited() {
        let prompt = AgyInvocation.composePrompt(Self.request(attachment: .inline("diff --git a/x b/x")))
        #expect(prompt.contains("<<<AGY-AGENT-ANEXO"))
        #expect(prompt.contains("diff --git a/x b/x"))
    }

    @Test("Anexo por arquivo não cola o conteúdo e anexa o diretório")
    func fileAttachmentIsReferenced() {
        let request = Self.request(attachment: .file(path: "/Users/tester/Repo/x.diff", contentDigest: "abc"))
        let prompt = AgyInvocation.composePrompt(request)
        #expect(prompt.contains("/Users/tester/Repo/x.diff"))
        #expect(!prompt.contains("<<<AGY-AGENT-ANEXO"))

        // Sem o diretório no workspace o agy não conseguiria ler o arquivo.
        let arguments = AgyInvocation.arguments(for: request)
        let pairs = zip(arguments, arguments.dropFirst())
        #expect(pairs.contains { $0 == "--add-dir" && $1 == "/Users/tester/Repo" })
    }

    @Test("Conteúdo diferente no mesmo caminho gera chave diferente")
    func fileDigestDiscriminates() {
        let before = Self.request(attachment: .file(path: "/x.diff", contentDigest: "a")).query.cacheKey
        let after = Self.request(attachment: .file(path: "/x.diff", contentDigest: "b")).query.cacheKey
        #expect(before != after)
    }

    @Test("Anexo vazio não gera seção")
    func emptyAttachmentIsOmitted() {
        #expect(!AgyInvocation.composePrompt(Self.request(attachment: .inline("   \n "))).contains("Material fornecido"))
        #expect(!AgyInvocation.composePrompt(Self.request(attachment: nil)).contains("Material fornecido"))
    }

    @Test("O orçamento de resposta é pedido no prompt")
    func budgetIsRequested() {
        let prompt = AgyInvocation.composePrompt(Self.request(mode: .verify))
        #expect(prompt.contains("\(Mode.verify.responseBudget) caracteres"))
    }

    @Test("Mudar o orçamento invalida a chave de cache")
    func budgetChangeInvalidatesCache() {
        let a = DelegationRequest(mode: .verify, question: "q", systemPrompt: "p", neutralDirectory: Self.neutral, responseBudget: 500)
        let b = DelegationRequest(mode: .verify, question: "q", systemPrompt: "p", neutralDirectory: Self.neutral, responseBudget: 900)
        #expect(a.query.cacheKey != b.query.cacheKey)
    }

    @Test("A montagem é determinística")
    func deterministic() {
        #expect(AgyInvocation.arguments(for: Self.request()) == AgyInvocation.arguments(for: Self.request()))
    }

    @Test("Pergunta vazia é rejeitada na validação")
    func emptyQuestionRejected() {
        #expect(throws: AgyAgentError.emptyQuestion) {
            try Self.request(question: "   \n ").validated()
        }
    }

    @Test("Modelo vazio, opção injetada e caracteres de controle são rejeitados")
    func invalidModelRejected() {
        for model in ["", "--dangerously-skip-permissions", "model name", "model\nother"] {
            #expect(throws: AgyAgentError.self) {
                try Self.request(model: model).validated()
            }
        }
        #expect(throws: Never.self) {
            try Self.request(model: "google/gemini-3.8:flash").validated()
        }
    }

    @Test("Modo inspect sem workspace é rejeitado")
    func inspectRequiresWorkspace() {
        #expect(throws: AgyAgentError.workspaceRequired(.inspect)) {
            try Self.request(mode: .inspect, workspace: nil).validated()
        }
    }

    @Test("A consulta derivada carrega digest do prompt e do anexo")
    func derivedQuery() {
        let query = Self.request(mode: .inspect, attachment: .inline("abc"), workspace: Self.repo).query
        #expect(query.workspaceRoot == "/Users/tester/Repo")
        #expect(query.attachmentDigest == Digest.sha256("abc"))
        #expect(query.model == Mode.inspect.defaultModel)
    }

    @Test("Editar o prompt de sistema invalida a chave de cache")
    func promptChangeInvalidatesCache() {
        let before = Self.request(systemPrompt: "v1").query.cacheKey
        let after = Self.request(systemPrompt: "v2").query.cacheKey
        #expect(before != after)
    }
}

@Suite("Retomada de conversa")
struct ConversationResumeTests {
    static let id = "31beabcd-8758-4f2e-b6ef-403f35042da9"

    static func request(conversationID: String?) -> DelegationRequest {
        DelegationRequest(
            mode: .verify,
            question: "E no macOS 26?",
            systemPrompt: "Responda com evidência.",
            neutralDirectory: AgyInvocationTests.neutral,
            conversationID: conversationID
        )
    }

    @Test("Sem conversa, --conversation não aparece")
    func absentByDefault() {
        let arguments = AgyInvocation.arguments(for: Self.request(conversationID: nil))
        #expect(!arguments.contains("--conversation"))
    }

    @Test("Com conversa, o identificador acompanha a opção e o prompt permanece no stdin")
    func presentWhenResuming() {
        let arguments = AgyInvocation.arguments(for: Self.request(conversationID: Self.id))
        #expect(zip(arguments, arguments.dropFirst()).contains { $0 == "--conversation" && $1 == Self.id })
        #expect(!arguments.contains { $0 == "--print" || $0.hasPrefix("--print=") })
        #expect(AgyInvocation.standardInput(for: Self.request(conversationID: Self.id)).contains("E no macOS 26?"))
    }

    @Test("Identificador fora do formato do agy é recusado na validação")
    func invalidIDIsRejected() {
        for bad in ["--model", "abc", "31beabcd;rm -rf", ""] {
            #expect(throws: AgyAgentError.self) {
                _ = try Self.request(conversationID: bad).validated()
            }
        }
        #expect(throws: Never.self) { _ = try Self.request(conversationID: Self.id).validated() }
    }

    @Test("A opção --conversation entra na análise e dispensa o cache")
    func parsingBypassesCache() throws {
        let parsed = try DelegationArguments.parse(
            mode: .verify,
            arguments: ["--conversation", Self.id, "e", "no", "macOS", "26?"],
            readStandardInput: { nil }
        )
        #expect(parsed.conversationID == Self.id)
        #expect(parsed.cachePolicy == .bypass)
        #expect(parsed.question == "e no macOS 26?")
    }

    @Test("Valor inválido em --conversation falha a análise")
    func parsingRejectsBadID() {
        #expect(throws: DelegationArguments.ParseError.self) {
            _ = try DelegationArguments.parse(
                mode: .verify,
                arguments: ["--conversation", "--model", "x"],
                readStandardInput: { nil }
            )
        }
    }
}
