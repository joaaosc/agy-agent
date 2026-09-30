import Testing
import Foundation
@testable import AgyAgentKit

@Suite("Identificação de quem chamou")
struct CallerTests {
    @Test("Claude Code é reconhecido pelas variáveis que exporta")
    func detectsClaudeCode() {
        #expect(Caller.detect(environment: ["CLAUDECODE": "1"]) == .claudeCode)
        #expect(Caller.detect(environment: ["CLAUDE_CODE_ENTRYPOINT": "cli"]) == .claudeCode)
    }

    @Test("Codex é reconhecido pelo prefixo das suas variáveis")
    func detectsCodex() {
        #expect(Caller.detect(environment: ["CODEX_SANDBOX": "1"]) == .codex)
    }

    @Test("Terminal comum e ambiente sem terminal são distinguidos")
    func detectsTerminalAndUnknown() {
        #expect(Caller.detect(environment: ["TERM": "xterm"]) == .terminal)
        #expect(Caller.detect(environment: [:]) == .unknown)
    }

    @Test("Claude Code vence quando ambas as marcas aparecem")
    func claudeWinsOverTerminal() {
        #expect(Caller.detect(environment: ["CLAUDECODE": "1", "TERM": "xterm"]) == .claudeCode)
    }
}

@Suite("Freio de gasto")
struct SpendGuardTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    func store(_ directory: borrowing TemporaryDirectory) throws -> PacketStore {
        try PacketStore(url: directory.url.appending(path: "cache.sqlite"), clock: { SpendGuardTests.now })
    }

    func packet(key: String, tokens: Int = 40_000, at date: Date = SpendGuardTests.now) -> EvidencePacket {
        EvidencePacket(
            cacheKey: key,
            query: Query(mode: .verify, question: key, model: "m", promptDigest: "p"),
            response: "r",
            usage: AgyEnvelope.Usage(inputTokens: tokens, outputTokens: 0, totalTokens: tokens),
            createdAt: date,
            caller: .claudeCode
        )
    }

    @Test("Sem histórico, a chamada passa")
    func allowsWhenEmpty() throws {
        let directory = try TemporaryDirectory()
        let verdict = SpendGuard(clock: { Self.now }).check(store: try store(directory))
        #expect(verdict.isAllowed)
    }

    @Test("Sem banco nenhum, a chamada passa")
    func allowsWithoutStore() {
        #expect(SpendGuard(clock: { Self.now }).check(store: nil).isAllowed)
    }

    @Test("O limite de chamadas barra a próxima")
    func blocksOnCallCount() throws {
        let directory = try TemporaryDirectory()
        let cache = try store(directory)
        for index in 0..<3 { try cache.store(packet(key: "c\(index)", tokens: 10)) }

        let guardian = SpendGuard(limits: .init(maxCalls: 3, maxAgyTokens: 10_000_000), clock: { Self.now })
        guard case .blocked(let reason) = guardian.check(store: cache) else {
            Issue.record("deveria ter barrado")
            return
        }
        #expect(reason.contains("3 chamadas"))
        #expect(reason.contains("config.toml"))
    }

    @Test("O limite de tokens barra a próxima")
    func blocksOnTokens() throws {
        let directory = try TemporaryDirectory()
        let cache = try store(directory)
        try cache.store(packet(key: "a", tokens: 60_000))

        let guardian = SpendGuard(limits: .init(maxCalls: 1000, maxAgyTokens: 50_000), clock: { Self.now })
        #expect(!guardian.check(store: cache).isAllowed)
    }

    @Test("Gasto fora da janela não conta")
    func ignoresOldSpending() throws {
        let directory = try TemporaryDirectory()
        // O store grava `last_used_at` com o próprio relógio; um store com
        // relógio antigo simula gasto de ontem.
        let old = try PacketStore(
            url: directory.url.appending(path: "cache.sqlite"),
            clock: { Self.now.addingTimeInterval(-86_400) }
        )
        for index in 0..<10 { try old.store(packet(key: "v\(index)")) }

        let current = try store(directory)
        let guardian = SpendGuard(limits: .init(maxCalls: 2, maxAgyTokens: 1000), clock: { Self.now })
        #expect(guardian.check(store: current).isAllowed)
    }

    @Test("Abaixo do limite, o veredito informa o quanto já foi usado")
    func reportsUsage() throws {
        let directory = try TemporaryDirectory()
        let cache = try store(directory)
        try cache.store(packet(key: "a", tokens: 1000))
        #expect(SpendGuard(clock: { Self.now }).check(store: cache) == .allowed(callsUsed: 1, tokensUsed: 1000))
    }

    @Test("Contadores reunidos respeitam os mesmos limites")
    func checksCombinedCounters() {
        let guardian = SpendGuard(limits: .init(maxCalls: 3, maxAgyTokens: 50_000))
        #expect(guardian.check(callsUsed: 2, tokensUsed: 49_999) == .allowed(callsUsed: 2, tokensUsed: 49_999))
        #expect(!guardian.check(callsUsed: 3, tokensUsed: 1).isAllowed)
        #expect(!guardian.check(callsUsed: 1, tokensUsed: 50_000).isAllowed)
    }

    @Test("Os limites vêm do config.toml")
    func limitsFromConfiguration() throws {
        let configuration = try Configuration.parse("""
        max_calls_per_window = 5
        max_agy_tokens_per_window = 123456
        """)
        #expect(configuration.limits.maxCalls == 5)
        #expect(configuration.limits.maxAgyTokens == 123_456)
    }

    @Test("Limite zero ou negativo é recusado na leitura")
    func rejectsInvalidLimits() {
        #expect(throws: AgyAgentError.self) { try Configuration.parse("max_calls_per_window = 0") }
        #expect(throws: AgyAgentError.self) { try Configuration.parse("max_agy_tokens_per_window = -1") }
    }
}

@Suite("Migração de esquema")
struct SchemaMigrationTests {
    @Test("Banco da versão 1 ganha a coluna de origem sem perder dados")
    func migratesFromV1() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "cache.sqlite")

        // Recria um banco no formato antigo, sem a coluna `caller`.
        let legacy = try SQLiteDatabase(url: url)
        try legacy.execute("CREATE TABLE schema_version (version INTEGER NOT NULL)")
        try legacy.run("INSERT INTO schema_version (version) VALUES (1)")
        try legacy.execute("""
            CREATE TABLE packets (
                cache_key TEXT PRIMARY KEY, id TEXT NOT NULL, packet_version INTEGER NOT NULL,
                mode TEXT NOT NULL, model TEXT NOT NULL, question TEXT NOT NULL,
                workspace_root TEXT, prompt_digest TEXT NOT NULL, attachment_digest TEXT,
                response TEXT NOT NULL, response_characters INTEGER NOT NULL,
                truncated INTEGER NOT NULL DEFAULT 0, conversation_id TEXT,
                input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
                thinking_tokens INTEGER NOT NULL DEFAULT 0, cache_read_tokens INTEGER NOT NULL DEFAULT 0,
                total_tokens INTEGER NOT NULL DEFAULT 0, duration_seconds REAL NOT NULL DEFAULT 0,
                agy_version TEXT NOT NULL, created_at REAL NOT NULL, last_used_at REAL NOT NULL,
                hits INTEGER NOT NULL DEFAULT 0
            )
            """)
        try legacy.run("""
            INSERT INTO packets (cache_key, id, packet_version, mode, model, question,
                prompt_digest, response, response_characters, agy_version, created_at, last_used_at)
            VALUES ('k', 'id', 1, 'verify', 'm', 'q', 'p', 'resposta antiga', 15, '1.2.7', 1000, 1000)
            """)

        // Abrir com a versão nova migra em vez de recriar.
        let store = try PacketStore(url: url)
        let packet = try #require(try store.storedPacket(forKey: "k"))
        #expect(packet.response == "resposta antiga")
        #expect(packet.caller == .unknown)

        // E passa a gravar a origem normalmente.
        try store.store(EvidencePacket(
            cacheKey: "novo",
            query: Query(mode: .verify, question: "q", model: "m", promptDigest: "p"),
            response: "r",
            caller: .codex
        ))
        #expect(try store.storedPacket(forKey: "novo")?.caller == .codex)
    }

    @Test("Chamadas por origem separam Claude Code de Codex")
    func callsByCaller() throws {
        let directory = try TemporaryDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try PacketStore(url: directory.url.appending(path: "cache.sqlite"), clock: { now })

        for (index, caller) in [Caller.claudeCode, .claudeCode, .codex].enumerated() {
            try store.store(EvidencePacket(
                cacheKey: "k\(index)",
                query: Query(mode: .verify, question: "q\(index)", model: "m", promptDigest: "p"),
                response: "r",
                caller: caller
            ))
        }
        let breakdown = try store.callsByCaller(since: now.addingTimeInterval(-3600))
        #expect(breakdown[.claudeCode] == 2)
        #expect(breakdown[.codex] == 1)
    }
}
