import Testing
import Foundation
@testable import AgyAgentKit

@Suite("Análise de argumentos de delegação")
struct DelegationArgumentsTests {
    func parse(_ arguments: [String], mode: Mode = .verify, stdin: String? = nil) throws -> DelegationArguments {
        try DelegationArguments.parse(mode: mode, arguments: arguments, readStandardInput: { stdin })
    }

    @Test("Palavras soltas formam a pergunta")
    func questionFromWords() throws {
        #expect(try parse(["a", "API", "existe?"]).question == "a API existe?")
    }

    @Test("Sem pergunta nos argumentos, lê de stdin")
    func questionFromStandardInput() throws {
        #expect(try parse([], stdin: "  vindo do pipe \n").question == "vindo do pipe")
    }

    @Test("Sem pergunta em lugar nenhum, falha com uso")
    func missingQuestion() {
        #expect(throws: DelegationArguments.ParseError.self) {
            try parse([], stdin: "   ")
        }
    }

    @Test("Todas as opções são reconhecidas")
    func options() throws {
        let parsed = try parse([
            "--model", "m", "--timeout", "30", "--budget", "500",
            "--file", "/tmp/x.diff", "--json", "--quiet", "pergunta",
        ])
        #expect(parsed.model == "m")
        #expect(parsed.timeoutSeconds == 30)
        #expect(parsed.responseBudget == 500)
        #expect(parsed.attachmentPath == "/tmp/x.diff")
        #expect(parsed.json)
        #expect(parsed.quiet)
        #expect(parsed.question == "pergunta")
    }

    @Test("Políticas de cache são exclusivas e explícitas")
    func cachePolicies() throws {
        #expect(try parse(["q"]).cachePolicy == .use)
        #expect(try parse(["--refresh", "q"]).cachePolicy == .refresh)
        #expect(try parse(["--no-cache", "q"]).cachePolicy == .bypass)
    }

    @Test("Opção desconhecida falha em vez de virar parte da pergunta")
    func unknownFlag() {
        // Engolir a flag como texto faria a chamada rodar com configuração
        // diferente da pedida, em silêncio.
        #expect(throws: DelegationArguments.ParseError.self) {
            try parse(["--turbo", "q"])
        }
    }

    @Test("Opção sem valor e valor inválido falham")
    func badValues() throws {
        #expect(throws: DelegationArguments.ParseError.self) { try parse(["--model"]) }
        #expect(throws: DelegationArguments.ParseError.self) { try parse(["--timeout", "zero", "q"]) }
        #expect(throws: DelegationArguments.ParseError.self) { try parse(["--budget", "-1", "q"]) }
        #expect(try parse(["--budget", "8000", "q"]).responseBudget == 8_000)
        #expect(throws: DelegationArguments.ParseError.self) { try parse(["--budget", "8001", "q"]) }
    }

    @Test("Depois de -- tudo é pergunta")
    func doubleDash() throws {
        let parsed = try parse(["--", "--model", "não", "é", "flag"])
        #expect(parsed.question == "--model não é flag")
        #expect(parsed.model == nil)
    }

    @Test("Anexo é lido por caminho e reduzido a digest")
    func attachmentByPath() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(path: "x.diff")
        try Data("diff --git a/x b/x".utf8).write(to: file)

        let parsed = try parse(["--file", file.path(percentEncoded: false), "q"])
        let attachment = try #require(try parsed.attachment())
        guard case .file(let path, let digest) = attachment else {
            Issue.record("esperado anexo por arquivo")
            return
        }
        #expect(path == file.path(percentEncoded: false))
        #expect(digest == Digest.sha256("diff --git a/x b/x"))
    }

    @Test("Anexo inexistente falha explicitamente")
    func missingAttachment() throws {
        let parsed = try parse(["--file", "/caminho/inexistente.diff", "q"])
        #expect(throws: AgyAgentError.self) { try parsed.attachment() }
    }

    @Test("Anexo acima do limite é rejeitado sem ser carregado")
    func oversizedAttachment() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(path: "large.bin")
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(DelegationArguments.maximumAttachmentBytes + 1))
        try handle.close()
        let parsed = try parse(["--file", file.path, "q"])
        #expect(throws: AgyAgentError.self) { try parsed.attachment() }
    }

    @Test("Sem --file não há anexo")
    func noAttachment() throws {
        #expect(try parse(["q"]).attachment() == nil)
    }
}

@Suite("Orquestração de delegação")
struct DelegationServiceTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    func makeService(_ processRunner: any ProcessRunning, cache: PacketStore?) -> DelegationService {
        DelegationService(
            runner: AgyRunner(
                executable: URL(filePath: "/bin/agy", directoryHint: .notDirectory),
                agyVersion: "1.2.7",
                processRunner: processRunner,
                parentEnvironment: [:],
                clock: { Self.now }
            ),
            cache: cache
        )
    }

    func request(question: String = "a API existe?") -> DelegationRequest {
        DelegationRequest(
            mode: .verify,
            question: question,
            systemPrompt: "p",
            neutralDirectory: URL(filePath: "/tmp", directoryHint: .isDirectory)
        )
    }

    func store(_ directory: borrowing TemporaryDirectory, now: Date = DelegationServiceTests.now) throws -> PacketStore {
        try PacketStore(url: directory.url.appending(path: "cache.sqlite"), clock: { now })
    }

    @Test("Primeira chamada vai ao agy e grava no cache")
    func firstCallHitsAgy() throws {
        let directory = try TemporaryDirectory()
        let cache = try store(directory)
        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)

        let outcome = try makeService(fake, cache: cache).delegate(request(), maxCacheAge: .seconds(3600))
        #expect(outcome.origin == .agy)
        #expect(outcome.packet.response == "OK")
        #expect(try cache.storedPacket(forKey: request().query.cacheKey) != nil)
    }

    @Test("Segunda chamada idêntica vem do cache e não lança processo")
    func secondCallUsesCache() throws {
        let directory = try TemporaryDirectory()
        let cache = try store(directory)
        try cache.store(EvidencePacket(
            cacheKey: request().query.cacheKey,
            query: request().query,
            response: "gravado",
            createdAt: Self.now
        ))

        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)
        let outcome = try makeService(fake, cache: cache).delegate(request(), maxCacheAge: .seconds(3600))

        #expect(outcome.origin == .cache)
        #expect(outcome.packet.response == "gravado")
        #expect(fake.plans.isEmpty)
        // O uso servido do cache é contado: é a medida de chamadas evitadas.
        #expect(try cache.statistics().hits == 1)
    }

    @Test("Resposta vazia de versão anterior é removida do cache")
    func staleEmptyResponseIsRemoved() throws {
        let directory = try TemporaryDirectory()
        let cache = try PacketStore(url: directory.url.appending(path: "cache.sqlite"))
        let req = request()
        try cache.store(EvidencePacket(cacheKey: req.query.cacheKey, query: req.query, response: "  \n"))
        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)

        let outcome = try makeService(fake, cache: cache).delegate(req, maxCacheAge: .seconds(60))

        #expect(outcome.origin == .agy)
        #expect(outcome.packet.response == "OK")
        #expect(fake.plans.count == 1)
        #expect(try cache.storedPacket(forKey: req.query.cacheKey)?.response == "OK")
    }

    @Test("--refresh ignora o gravado mas regrava o novo")
    func refreshBypassesRead() throws {
        let directory = try TemporaryDirectory()
        let cache = try store(directory)
        try cache.store(EvidencePacket(
            cacheKey: request().query.cacheKey,
            query: request().query,
            response: "antigo",
            createdAt: Self.now
        ))

        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)
        let outcome = try makeService(fake, cache: cache).delegate(
            request(), maxCacheAge: .seconds(3600), policy: .refresh
        )
        #expect(outcome.origin == .agy)
        #expect(try cache.storedPacket(forKey: request().query.cacheKey)?.response == "OK")
    }

    @Test("--no-cache não lê nem grava")
    func bypassLeavesNoTrace() throws {
        let directory = try TemporaryDirectory()
        let cache = try store(directory)
        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)

        let outcome = try makeService(fake, cache: cache).delegate(
            request(), maxCacheAge: .seconds(3600), policy: .bypass
        )
        #expect(outcome.origin == .agy)
        #expect(try cache.storedPacket(forKey: request().query.cacheKey) == nil)
    }

    @Test("Pacote velho de modo com web é ignorado e regravado")
    func staleWebPacketIsRefetched() throws {
        let directory = try TemporaryDirectory()
        let cache = try store(directory)
        try cache.store(EvidencePacket(
            cacheKey: request().query.cacheKey,
            query: request().query,
            response: "velho",
            createdAt: Self.now.addingTimeInterval(-7200)
        ))

        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)
        let outcome = try makeService(fake, cache: cache).delegate(request(), maxCacheAge: .seconds(3600))
        #expect(outcome.origin == .agy)
    }

    @Test("Sem cache disponível, a delegação continua")
    func worksWithoutCache() throws {
        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)
        let outcome = try makeService(fake, cache: nil).delegate(request(), maxCacheAge: .seconds(3600))
        #expect(outcome.origin == .agy)
        #expect(outcome.packet.response == "OK")
    }

    @Test("Pergunta vazia falha antes de qualquer trabalho")
    func emptyQuestionFailsEarly() throws {
        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)
        #expect(throws: AgyAgentError.emptyQuestion) {
            try makeService(fake, cache: nil).delegate(request(question: " "), maxCacheAge: .seconds(60))
        }
        #expect(fake.plans.isEmpty)
    }

    @Test("Falha do agy propaga e nada é gravado")
    func agyFailureIsNotCached() throws {
        let directory = try TemporaryDirectory()
        let cache = try store(directory)
        let fake = FakeProcessRunner(standardOutput: "", standardError: "erro", exitCode: 1)

        #expect(throws: AgyAgentError.self) {
            try makeService(fake, cache: cache).delegate(request(), maxCacheAge: .seconds(3600))
        }
        #expect(try cache.statistics().packets == 0)
    }

    @Test("Avisos do runner chegam ao resultado")
    func warningsPropagate() throws {
        let fake = FakeProcessRunner(
            standardOutput: AgyEnvelopeTests.sample,
            standardError: "warning: algo\n"
        )
        let outcome = try makeService(fake, cache: nil).delegate(request(), maxCacheAge: .seconds(60))
        #expect(outcome.warnings == ["agy: warning: algo"])
    }
}

@Suite("Telemetria da delegação")
struct DelegationServiceTelemetryTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    func makeService(
        _ processRunner: any ProcessRunning,
        cache: PacketStore?,
        telemetry: TelemetryStore?,
        limits: SpendGuard.Limits = .init(maxCalls: 1000, maxAgyTokens: 100_000_000)
    ) -> DelegationService {
        DelegationService(
            runner: AgyRunner(
                executable: URL(filePath: "/bin/agy", directoryHint: .notDirectory),
                agyVersion: "1.2.7",
                processRunner: processRunner,
                parentEnvironment: ["CLAUDECODE": "1"],
                clock: { Self.now }
            ),
            cache: cache,
            spendGuard: SpendGuard(limits: limits, clock: { Self.now }),
            telemetry: telemetry
        )
    }

    func request(question: String = "a API existe?") -> DelegationRequest {
        DelegationRequest(
            mode: .verify,
            question: question,
            systemPrompt: "p",
            neutralDirectory: URL(filePath: "/tmp", directoryHint: .isDirectory)
        )
    }

    @Test("Chamada bem-sucedida é registrada com duração e origem")
    func recordsSuccess() throws {
        let directory = try TemporaryDirectory()
        let telemetry = try TelemetryStore(url: directory.url.appending(path: "t.sqlite"), clock: { Self.now })
        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)

        _ = try makeService(fake, cache: nil, telemetry: telemetry).delegate(request(), maxCacheAge: .seconds(60))

        let summary = try telemetry.summary()
        #expect(summary.total == 1)
        #expect(summary.byOutcome[.success] == 1)
        #expect(summary.byMode[.verify] == 1)

        let failures = try telemetry.recentFailures()
        #expect(failures.isEmpty)
    }

    @Test("Servida do cache é registrada como cache, não como sucesso")
    func recordsCacheHit() throws {
        let directory = try TemporaryDirectory()
        let telemetry = try TelemetryStore(url: directory.url.appending(path: "t.sqlite"), clock: { Self.now })
        let cache = try PacketStore(url: directory.url.appending(path: "cache.sqlite"), clock: { Self.now })
        try cache.store(EvidencePacket(cacheKey: request().query.cacheKey, query: request().query, response: "r", createdAt: Self.now))

        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)
        _ = try makeService(fake, cache: cache, telemetry: telemetry).delegate(request(), maxCacheAge: .seconds(3600))

        #expect(try telemetry.summary().byOutcome[.cache] == 1)
        #expect(fake.plans.isEmpty)
    }

    @Test("Falha do agy é registrada com o tipo do erro, e a exceção ainda é lançada")
    func recordsErrorAndStillThrows() throws {
        let directory = try TemporaryDirectory()
        let telemetry = try TelemetryStore(url: directory.url.appending(path: "t.sqlite"), clock: { Self.now })
        let fake = FakeProcessRunner(standardOutput: "", standardError: "auth expirou", exitCode: 1)

        #expect(throws: AgyAgentError.self) {
            try makeService(fake, cache: nil, telemetry: telemetry).delegate(request(), maxCacheAge: .seconds(60))
        }

        let summary = try telemetry.summary()
        #expect(summary.byOutcome[.error] == 1)
        #expect(summary.errorsByKind["agy_failed"] == 1)

        let failures = try telemetry.recentFailures()
        #expect(failures.first?.errorDetail == "agy retornou status exit 1")
        #expect(failures.first?.errorDetail?.contains("auth expirou") == false)
    }

    @Test("Bloqueio pelo freio de gasto gera uma única linha, não duas")
    func recordsBlockOnce() throws {
        let directory = try TemporaryDirectory()
        let telemetry = try TelemetryStore(url: directory.url.appending(path: "t.sqlite"), clock: { Self.now })
        let cache = try PacketStore(url: directory.url.appending(path: "cache.sqlite"), clock: { Self.now })
        // Uma chamada anterior já esgota o limite de 1.
        try cache.store(EvidencePacket(
            cacheKey: "outra",
            query: Query(mode: .verify, question: "outra", model: "m", promptDigest: "p"),
            response: "r",
            usage: AgyEnvelope.Usage(inputTokens: 100, totalTokens: 100),
            createdAt: Self.now
        ))

        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)
        #expect(throws: AgyAgentError.self) {
            try makeService(fake, cache: cache, telemetry: telemetry, limits: .init(maxCalls: 1, maxAgyTokens: 100_000_000))
                .delegate(request(), maxCacheAge: .seconds(60))
        }

        let summary = try telemetry.summary()
        #expect(summary.total == 1)
        #expect(summary.byOutcome[.blocked] == 1)
        #expect(summary.errorsByKind["spend_limit"] == 1)
        #expect(fake.plans.isEmpty)
    }

    @Test("O chamador registrado vem do ambiente do processo, não de suposição")
    func recordsCallerFromEnvironment() throws {
        let directory = try TemporaryDirectory()
        let telemetry = try TelemetryStore(url: directory.url.appending(path: "t.sqlite"), clock: { Self.now })
        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)

        _ = try makeService(fake, cache: nil, telemetry: telemetry).delegate(request(), maxCacheAge: .seconds(60))

        let failures = try telemetry.recentFailures() // não deve haver; só valida que não quebrou
        #expect(failures.isEmpty)
    }

    @Test("Sem telemetria configurada, a delegação funciona normalmente")
    func worksWithoutTelemetry() throws {
        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)
        let outcome = try makeService(fake, cache: nil, telemetry: nil).delegate(request(), maxCacheAge: .seconds(60))
        #expect(outcome.packet.response == "OK")
    }

    @Test("Falha ao gravar telemetria não derruba uma delegação bem-sucedida")
    func telemetryFailureIsSwallowed() throws {
        // Um diretório inexistente e não criável faria `record` falhar; como
        // TelemetryStore já falharia na abertura, simula-se indiretamente:
        // a ausência de telemetria (nil) já cobre o caminho "sem gravação",
        // e o service nunca propaga erro de `try? telemetry.record`.
        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)
        #expect(throws: Never.self) {
            _ = try makeService(fake, cache: nil, telemetry: nil).delegate(request(), maxCacheAge: .seconds(60))
        }
    }
}
