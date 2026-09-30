import Foundation

/// Persistência de pacotes de evidência.
///
/// Existem duas instâncias em uso, com o mesmo esquema e propósitos opostos:
///
/// - `cache.sqlite`, em `~/Library/Caches`, memoização descartável. Apagar o
///   arquivo tem que ser sempre seguro.
/// - `knowledge.sqlite`, em `~/Library/Application Support`, pacotes promovidos
///   de propósito, nunca descartados automaticamente.
///
/// O store também é onde a economia é medida. `hits` conta quantas vezes uma
/// resposta foi servida sem chamar o `agy`; `response_characters` registra o
/// tamanho do que voltou para o chamador, que é o custo real da delegação.
public final class PacketStore: @unchecked Sendable {
    public static let schemaVersion = 2

    private let database: SQLiteDatabase
    private let clock: @Sendable () -> Date

    public var url: URL { database.url }

    public init(url: URL, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        try PacketStore.prepareDirectory(for: url)
        self.database = try SQLiteDatabase(url: url)
        self.clock = clock
        try migrate()
    }

    /// Cria o diretório do banco com permissão restrita.
    ///
    /// Os pacotes guardam perguntas, trechos de código e caminhos do
    /// repositório. Nada disso deve ficar legível para outros usuários da
    /// máquina, e `0o700` é o que o sistema não garante por padrão em
    /// `~/Library/Caches`.
    static func prepareDirectory(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw AgyAgentError.storeFailed("criar \(directory.path(percentEncoded: false)): \(error.localizedDescription)")
        }
    }

    // MARK: - Esquema

    /// Migração idempotente.
    ///
    /// Duas sessões podem abrir o banco ao mesmo tempo e tentar migrar juntas;
    /// por isso a transação é `BEGIN IMMEDIATE` e todo DDL é `IF NOT EXISTS`.
    private func migrate() throws {
        try database.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
        try database.transaction {
            let rows = try database.query("SELECT version FROM schema_version LIMIT 1")
            let current = rows.first.flatMap { try? $0.int("version") } ?? 0
            guard current < Self.schemaVersion else { return }

            if current < 1 {
                try database.execute(Self.schemaV1)
            }
            if current < 2 {
                // Bancos criados na versão 1 ganham a coluna sem perder dados.
                // `IF NOT EXISTS` não existe em ALTER TABLE do SQLite, então o
                // erro de coluna repetida é tolerado: o efeito já está lá.
                try? database.execute("ALTER TABLE packets ADD COLUMN caller TEXT NOT NULL DEFAULT 'unknown'")
            }

            if rows.isEmpty {
                try database.run("INSERT INTO schema_version (version) VALUES (?)", [SQLiteValue(Self.schemaVersion)])
            } else {
                try database.run("UPDATE schema_version SET version = ?", [SQLiteValue(Self.schemaVersion)])
            }
        }
    }

    private static let schemaV1 = """
        CREATE TABLE IF NOT EXISTS packets (
            cache_key           TEXT PRIMARY KEY,
            id                  TEXT NOT NULL,
            packet_version      INTEGER NOT NULL,
            mode                TEXT NOT NULL,
            model               TEXT NOT NULL,
            question            TEXT NOT NULL,
            workspace_root      TEXT,
            prompt_digest       TEXT NOT NULL,
            attachment_digest   TEXT,
            response            TEXT NOT NULL,
            response_characters INTEGER NOT NULL,
            truncated           INTEGER NOT NULL DEFAULT 0,
            conversation_id     TEXT,
            input_tokens        INTEGER NOT NULL DEFAULT 0,
            output_tokens       INTEGER NOT NULL DEFAULT 0,
            thinking_tokens     INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens   INTEGER NOT NULL DEFAULT 0,
            total_tokens        INTEGER NOT NULL DEFAULT 0,
            duration_seconds    REAL NOT NULL DEFAULT 0,
            agy_version         TEXT NOT NULL,
            caller              TEXT NOT NULL DEFAULT 'unknown',
            created_at          REAL NOT NULL,
            last_used_at        REAL NOT NULL,
            hits                INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS packets_created_at ON packets (created_at);
        CREATE INDEX IF NOT EXISTS packets_mode ON packets (mode);
        """

    // MARK: - Leitura

    /// Pacote memoizado, se existir e ainda estiver fresco.
    ///
    /// A decisão de frescor é do próprio pacote: modos que dependem da web
    /// envelhecem, os demais só são invalidados por mudança de digest.
    public func packet(forKey cacheKey: String, maxAge: Duration) throws -> EvidencePacket? {
        guard let packet = try storedPacket(forKey: cacheKey) else { return nil }
        guard packet.isFresh(at: clock(), maxAge: maxAge) else { return nil }
        return packet
    }

    /// Pacote armazenado, ignorando frescor.
    public func storedPacket(forKey cacheKey: String) throws -> EvidencePacket? {
        let rows = try database.query("SELECT * FROM packets WHERE cache_key = ? LIMIT 1", [.text(cacheKey)])
        guard let row = rows.first else { return nil }
        return try Self.packet(from: row)
    }

    public func allPackets(limit: Int = 100) throws -> [EvidencePacket] {
        let rows = try database.query(
            "SELECT * FROM packets ORDER BY created_at DESC LIMIT ?",
            [SQLiteValue(limit)]
        )
        return try rows.map(Self.packet(from:))
    }

    /// Registra o uso de um pacote servido do cache.
    ///
    /// `hits` é a medida direta de chamadas ao `agy` que não aconteceram.
    public func recordHit(forKey cacheKey: String) throws {
        try database.run(
            "UPDATE packets SET hits = hits + 1, last_used_at = ? WHERE cache_key = ?",
            [SQLiteValue(clock().timeIntervalSince1970), .text(cacheKey)]
        )
    }

    // MARK: - Escrita

    /// Grava o pacote, substituindo o que houver na mesma chave.
    ///
    /// Idempotente de propósito: duas sessões que façam a mesma pergunta em
    /// paralelo devem convergir para uma linha, não falhar. `hits` é
    /// preservado na atualização, porque mede o uso da chave, não da resposta.
    public func store(_ packet: EvidencePacket) throws {
        let now = clock().timeIntervalSince1970
        try database.run(
            """
            INSERT INTO packets (
                cache_key, id, packet_version, mode, model, question, workspace_root,
                prompt_digest, attachment_digest, response, response_characters, truncated,
                conversation_id, input_tokens, output_tokens, thinking_tokens,
                cache_read_tokens, total_tokens, duration_seconds, agy_version, caller,
                created_at, last_used_at, hits
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(cache_key) DO UPDATE SET
                id = excluded.id,
                packet_version = excluded.packet_version,
                model = excluded.model,
                response = excluded.response,
                response_characters = excluded.response_characters,
                truncated = excluded.truncated,
                conversation_id = excluded.conversation_id,
                input_tokens = excluded.input_tokens,
                output_tokens = excluded.output_tokens,
                thinking_tokens = excluded.thinking_tokens,
                cache_read_tokens = excluded.cache_read_tokens,
                total_tokens = excluded.total_tokens,
                duration_seconds = excluded.duration_seconds,
                agy_version = excluded.agy_version,
                caller = excluded.caller,
                created_at = excluded.created_at,
                last_used_at = excluded.last_used_at
            """,
            [
                .text(packet.cacheKey),
                .text(packet.id.uuidString),
                SQLiteValue(packet.schemaVersion),
                .text(packet.query.mode.rawValue),
                .text(packet.query.model),
                .text(packet.query.question),
                SQLiteValue(packet.query.workspaceRoot),
                .text(packet.query.promptDigest),
                SQLiteValue(packet.query.attachmentDigest),
                .text(packet.response),
                SQLiteValue(packet.responseCharacters),
                SQLiteValue(packet.truncated),
                SQLiteValue(packet.conversationID),
                SQLiteValue(packet.usage.inputTokens),
                SQLiteValue(packet.usage.outputTokens),
                SQLiteValue(packet.usage.thinkingTokens),
                SQLiteValue(packet.usage.cacheReadTokens),
                SQLiteValue(packet.usage.totalTokens),
                SQLiteValue(packet.durationSeconds),
                .text(packet.agyVersion),
                .text(packet.caller.rawValue),
                SQLiteValue(packet.createdAt.timeIntervalSince1970),
                SQLiteValue(now),
            ]
        )
    }

    public func remove(key cacheKey: String) throws {
        try database.run("DELETE FROM packets WHERE cache_key = ?", [.text(cacheKey)])
    }

    /// Copia um pacote deste store para outro.
    ///
    /// É assim que um resultado sai do cache descartável e vira conhecimento
    /// durável: por ato explícito, nunca automaticamente.
    @discardableResult
    public func promote(key cacheKey: String, to destination: PacketStore) throws -> EvidencePacket {
        guard let packet = try storedPacket(forKey: cacheKey) else {
            throw AgyAgentError.storeFailed("pacote \(cacheKey) não encontrado em \(url.lastPathComponent)")
        }
        try destination.store(packet)
        return packet
    }

    // MARK: - Medição

    public struct Statistics: Sendable, Equatable {
        public var packets: Int
        public var hits: Int
        public var responseCharacters: Int
        /// `output_tokens` do envelope. **Não** é o tamanho da resposta final:
        /// inclui o turno inteiro do agente — chamadas de ferramenta e texto
        /// intermediário. Medido: 2 582 tokens para 556 caracteres de resposta.
        /// Serve para saber o custo do lado do Gemini, não a economia aqui.
        public var agyOutputTokens: Int
        public var agyTokens: Int
        public var truncated: Int

        /// Caracteres que não voltaram ao chamador porque a resposta já estava
        /// em cache. Medida exata, e a única direta que existe.
        public var charactersServedFromCache: Int
        public var agyOutputTokensAvoided: Int

        /// Estimativa do que o cache poupou no contexto de quem chamou.
        ///
        /// É estimativa, não medida: o tokenizador do chamador não está
        /// disponível aqui. Quatro caracteres por token é a aproximação usual
        /// para texto latino.
        public var estimatedCallerTokensSaved: Int { charactersServedFromCache / 4 }

        public init(
            packets: Int = 0,
            hits: Int = 0,
            responseCharacters: Int = 0,
            agyOutputTokens: Int = 0,
            agyTokens: Int = 0,
            truncated: Int = 0,
            charactersServedFromCache: Int = 0,
            agyOutputTokensAvoided: Int = 0
        ) {
            self.packets = packets
            self.hits = hits
            self.responseCharacters = responseCharacters
            self.agyOutputTokens = agyOutputTokens
            self.agyTokens = agyTokens
            self.truncated = truncated
            self.charactersServedFromCache = charactersServedFromCache
            self.agyOutputTokensAvoided = agyOutputTokensAvoided
        }
    }

    public func statistics() throws -> Statistics {
        let rows = try database.query(
            """
            SELECT
                COUNT(*)                                   AS packets,
                COALESCE(SUM(hits), 0)                     AS hits,
                COALESCE(SUM(response_characters), 0)      AS response_characters,
                COALESCE(SUM(output_tokens), 0)            AS agy_output_tokens,
                COALESCE(SUM(total_tokens), 0)             AS agy_tokens,
                COALESCE(SUM(truncated), 0)                AS truncated,
                COALESCE(SUM(hits * response_characters), 0) AS cached_characters,
                COALESCE(SUM(hits * output_tokens), 0)     AS avoided_output_tokens
            FROM packets
            """
        )
        guard let row = rows.first else { return Statistics() }
        return Statistics(
            packets: try row.int("packets"),
            hits: try row.int("hits"),
            responseCharacters: try row.int("response_characters"),
            agyOutputTokens: try row.int("agy_output_tokens"),
            agyTokens: try row.int("agy_tokens"),
            truncated: try row.int("truncated"),
            charactersServedFromCache: try row.int("cached_characters"),
            agyOutputTokensAvoided: try row.int("avoided_output_tokens")
        )
    }

    /// Resumo restrito a uma janela de tempo, para o relatório de economia.
    ///
    /// O filtro é por `last_used_at`, não por `created_at`: um pacote gravado
    /// ontem e servido do cache hoje representa trabalho poupado hoje.
    public func delegationSummary(since: Date) throws -> SavingsReport.Delegation {
        let rows = try database.query(
            """
            SELECT
                COUNT(*)                                     AS calls,
                COALESCE(SUM(hits), 0)                       AS hits,
                COALESCE(SUM(response_characters), 0)        AS characters,
                COALESCE(SUM(hits * response_characters), 0) AS cached_characters,
                COALESCE(SUM(input_tokens), 0)               AS input_tokens,
                COALESCE(SUM(output_tokens), 0)              AS output_tokens
            FROM packets WHERE last_used_at >= ?
            """,
            [SQLiteValue(since.timeIntervalSince1970)]
        )
        guard let row = rows.first else { return SavingsReport.Delegation() }
        return SavingsReport.Delegation(
            calls: try row.int("calls"),
            cacheHits: try row.int("hits"),
            responseCharacters: try row.int("characters"),
            charactersFromCache: try row.int("cached_characters"),
            agyInputTokens: try row.int("input_tokens"),
            agyOutputTokens: try row.int("output_tokens")
        )
    }

    /// Chamadas por origem na janela. Responde, com dado e não com memória,
    /// se a delegação está mesmo sendo usada no Codex.
    public func callsByCaller(since: Date) throws -> [Caller: Int] {
        let rows = try database.query(
            "SELECT caller, COUNT(*) AS total FROM packets WHERE last_used_at >= ? GROUP BY caller",
            [SQLiteValue(since.timeIntervalSince1970)]
        )
        var result: [Caller: Int] = [:]
        for row in rows {
            let caller = Caller(rawValue: row.optionalText("caller") ?? "") ?? .unknown
            result[caller, default: 0] += try row.int("total")
        }
        return result
    }

    /// Remove pacotes mais antigos que `maxAge`. Só faz sentido no cache.
    @discardableResult
    public func prune(olderThan maxAge: Duration) throws -> Int {
        let cutoff = clock().timeIntervalSince1970 - Double(maxAge.components.seconds)
        let before = try statistics().packets
        try database.run("DELETE FROM packets WHERE created_at < ?", [SQLiteValue(cutoff)])
        return before - (try statistics().packets)
    }

    // MARK: - Mapeamento

    private static func packet(from row: SQLiteRow) throws -> EvidencePacket {
        let query = Query(
            mode: Mode(rawValue: try row.text("mode")) ?? .research,
            question: try row.text("question"),
            model: try row.text("model"),
            workspaceRoot: row.optionalText("workspace_root"),
            promptDigest: try row.text("prompt_digest"),
            attachmentDigest: row.optionalText("attachment_digest")
        )
        let usage = AgyEnvelope.Usage(
            inputTokens: try row.int("input_tokens"),
            outputTokens: try row.int("output_tokens"),
            thinkingTokens: try row.int("thinking_tokens"),
            cacheReadTokens: try row.int("cache_read_tokens"),
            totalTokens: try row.int("total_tokens")
        )
        return EvidencePacket(
            id: UUID(uuidString: try row.text("id")) ?? UUID(),
            schemaVersion: try row.int("packet_version"),
            cacheKey: try row.text("cache_key"),
            query: query,
            response: try row.text("response"),
            conversationID: row.optionalText("conversation_id"),
            usage: usage,
            durationSeconds: try row.real("duration_seconds"),
            agyVersion: try row.text("agy_version"),
            createdAt: Date(timeIntervalSince1970: try row.real("created_at")),
            truncated: try row.bool("truncated"),
            caller: Caller(rawValue: row.optionalText("caller") ?? "") ?? .unknown
        )
    }
}
