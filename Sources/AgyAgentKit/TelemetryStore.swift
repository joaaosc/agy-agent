import Foundation

/// Persistência de `AttemptRecord`: um diário, não um cache.
///
/// Cada linha é uma tentativa de delegação — sucesso, cache, erro ou
/// bloqueio pelo freio de gasto. É a fonte de dados para diagnosticar, mais
/// tarde, onde a ferramenta falha com que frequência e em qual modo.
///
/// Nunca deve interromper uma delegação: toda escrita, do lado de quem chama,
/// é feita com `try?`. Perder um registro de telemetria é aceitável; falhar
/// uma resposta por causa dele não é.
public final class TelemetryStore: @unchecked Sendable {
    public static let schemaVersion = 3

    private let database: SQLiteDatabase
    private let clock: @Sendable () -> Date

    public var url: URL { database.url }

    public init(url: URL, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        // Reaproveita a criação de diretório com permissão 0o700 do
        // PacketStore: mesma política, mesmo motivo — nenhum outro usuário da
        // máquina deve ler isto.
        try PacketStore.prepareDirectory(for: url)
        self.database = try SQLiteDatabase(url: url)
        self.clock = clock
        try migrate()
    }

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
                try database.execute(Self.schemaV2)
            }
            if current < 3 {
                try database.execute(Self.schemaV3)
            }
            if current < Self.schemaVersion {
                if rows.isEmpty {
                    try database.run("INSERT INTO schema_version (version) VALUES (?)", [SQLiteValue(Self.schemaVersion)])
                } else {
                    try database.run("UPDATE schema_version SET version = ?", [SQLiteValue(Self.schemaVersion)])
                }
            }
        }
    }

    private static let schemaV1 = """
        CREATE TABLE IF NOT EXISTS attempts (
            id                   INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at           REAL NOT NULL,
            mode                 TEXT NOT NULL,
            model                TEXT NOT NULL,
            caller               TEXT NOT NULL,
            outcome              TEXT NOT NULL,
            error_kind           TEXT,
            error_detail         TEXT,
            duration_seconds     REAL,
            response_characters  INTEGER,
            truncated            INTEGER NOT NULL DEFAULT 0,
            had_workspace        INTEGER NOT NULL DEFAULT 0,
            had_attachment       INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS attempts_created_at ON attempts (created_at);
        CREATE INDEX IF NOT EXISTS attempts_outcome ON attempts (outcome);
        """

    private static let schemaV2 = """
        CREATE TABLE IF NOT EXISTS external_usage (
            id                   INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at           REAL NOT NULL,
            role                 TEXT NOT NULL,
            input_tokens         INTEGER NOT NULL DEFAULT 0,
            output_tokens        INTEGER NOT NULL DEFAULT 0,
            duration_seconds     REAL,
            response_characters  INTEGER NOT NULL DEFAULT 0,
            success              INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS external_usage_created_at ON external_usage (created_at);
        """

    private static let schemaV3 = """
        ALTER TABLE external_usage ADD COLUMN backend_duration_seconds REAL;
        ALTER TABLE external_usage ADD COLUMN num_turns INTEGER NOT NULL DEFAULT 0;
        """

    /// Uso do executor externo. O registro contém somente métricas agregáveis:
    /// nunca recebe prompt, resposta, diretório ou credenciais.
    public struct ExternalUsageRecord: Sendable, Equatable {
        public var timestamp: Date
        public var role: String
        public var inputTokens: Int
        public var outputTokens: Int
        /// Tempo total observado pelo bridge, incluindo inicialização e encerramento.
        public var durationSeconds: Double?
        /// Tempo informado pelo runtime para o turno, sem o overhead do processo.
        public var backendDurationSeconds: Double?
        public var numTurns: Int
        public var responseCharacters: Int
        public var success: Bool

        public init(
            timestamp: Date,
            role: String,
            inputTokens: Int = 0,
            outputTokens: Int = 0,
            durationSeconds: Double? = nil,
            backendDurationSeconds: Double? = nil,
            numTurns: Int = 0,
            responseCharacters: Int = 0,
            success: Bool
        ) {
            self.timestamp = timestamp
            self.role = String(role.prefix(128))
            self.inputTokens = max(0, inputTokens)
            self.outputTokens = max(0, outputTokens)
            self.durationSeconds = durationSeconds.map { max(0, $0) }
            self.backendDurationSeconds = backendDurationSeconds.map { max(0, $0) }
            self.numTurns = max(0, numTurns)
            self.responseCharacters = max(0, responseCharacters)
            self.success = success
        }
    }

    public struct ExternalLatencyRecord: Sendable, Equatable {
        public var timestamp: Date
        public var role: String
        public var durationSeconds: Double?
        public var backendDurationSeconds: Double?
        public var numTurns: Int
        public var totalTokens: Int
        public var success: Bool
    }

    public struct ExternalUsageSummary: Sendable, Equatable {
        public var calls: Int
        public var inputTokens: Int
        public var outputTokens: Int
        public var responseCharacters: Int
        public var successfulCalls: Int

        public init(calls: Int = 0, inputTokens: Int = 0, outputTokens: Int = 0, responseCharacters: Int = 0, successfulCalls: Int = 0) {
            self.calls = calls
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.responseCharacters = responseCharacters
            self.successfulCalls = successfulCalls
        }
    }

    // MARK: - Escrita

    public func record(_ record: AttemptRecord) throws {
        try database.run(
            """
            INSERT INTO attempts (
                created_at, mode, model, caller, outcome, error_kind, error_detail,
                duration_seconds, response_characters, truncated, had_workspace, had_attachment
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                SQLiteValue(record.timestamp.timeIntervalSince1970),
                .text(record.mode.rawValue),
                .text(record.model),
                .text(record.caller.rawValue),
                .text(record.outcome.rawValue),
                SQLiteValue(record.errorKind),
                SQLiteValue(record.errorDetail),
                record.durationSeconds.map(SQLiteValue.init) ?? .null,
                record.responseCharacters.map(SQLiteValue.init) ?? .null,
                SQLiteValue(record.truncated),
                SQLiteValue(record.hadWorkspace),
                SQLiteValue(record.hadAttachment),
            ]
        )
    }

    public func recordExternalUsage(_ record: ExternalUsageRecord) throws {
        try database.run(
            """
            INSERT INTO external_usage (
                created_at, role, input_tokens, output_tokens, duration_seconds,
                backend_duration_seconds, num_turns, response_characters, success
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                SQLiteValue(record.timestamp.timeIntervalSince1970),
                .text(record.role),
                SQLiteValue(record.inputTokens),
                SQLiteValue(record.outputTokens),
                record.durationSeconds.map(SQLiteValue.init) ?? .null,
                record.backendDurationSeconds.map(SQLiteValue.init) ?? .null,
                SQLiteValue(record.numTurns),
                SQLiteValue(record.responseCharacters),
                SQLiteValue(record.success),
            ]
        )
    }

    public func externalUsageSummary(since: Date = .distantPast) throws -> ExternalUsageSummary {
        let rows = try database.query(
            """
            SELECT COUNT(*) AS calls,
                   COALESCE(SUM(CASE WHEN success = 1 THEN input_tokens ELSE 0 END), 0) AS input_tokens,
                   COALESCE(SUM(CASE WHEN success = 1 THEN output_tokens ELSE 0 END), 0) AS output_tokens,
                   COALESCE(SUM(CASE WHEN success = 1 THEN response_characters ELSE 0 END), 0) AS response_characters,
                   COALESCE(SUM(success), 0) AS successful_calls
            FROM external_usage WHERE created_at >= ?
            """,
            [SQLiteValue(since.timeIntervalSince1970)]
        )
        guard let row = rows.first else { return ExternalUsageSummary() }
        return ExternalUsageSummary(
            calls: try row.int("calls"),
            inputTokens: try row.int("input_tokens"),
            outputTokens: try row.int("output_tokens"),
            responseCharacters: try row.int("response_characters"),
            successfulCalls: try row.int("successful_calls")
        )
    }

    /// Amostras recentes sem conteúdo do usuário. Servem para distinguir
    /// overhead do processo de tempo efetivamente gasto em turnos e ferramentas.
    public func recentExternalLatency(limit: Int = 20) throws -> [ExternalLatencyRecord] {
        let rows = try database.query(
            """
            SELECT created_at, role, duration_seconds, backend_duration_seconds,
                   num_turns, input_tokens + output_tokens AS total_tokens, success
            FROM external_usage ORDER BY created_at DESC LIMIT ?
            """,
            [SQLiteValue(max(1, min(limit, 100)))]
        )
        return try rows.map { row in
            func optionalDouble(_ name: String) -> Double? {
                switch row.columns[name] {
                case .real(let value): value
                case .integer(let value): Double(value)
                default: nil
                }
            }
            return ExternalLatencyRecord(
                timestamp: Date(timeIntervalSince1970: try row.real("created_at")),
                role: try row.text("role"),
                durationSeconds: optionalDouble("duration_seconds"),
                backendDurationSeconds: optionalDouble("backend_duration_seconds"),
                numTurns: try row.int("num_turns"),
                totalTokens: try row.int("total_tokens"),
                success: try row.bool("success")
            )
        }
    }

    // MARK: - Leitura

    public struct Summary: Sendable, Equatable {
        public var total: Int
        public var byOutcome: [AttemptRecord.Outcome: Int]
        public var byMode: [Mode: Int]
        public var errorsByKind: [String: Int]
        /// Média só das tentativas que de fato chamaram o agy (sucesso ou erro
        /// depois de lançar o processo); cache e bloqueio não têm duração.
        public var averageDurationSeconds: Double?

        public init(
            total: Int = 0,
            byOutcome: [AttemptRecord.Outcome: Int] = [:],
            byMode: [Mode: Int] = [:],
            errorsByKind: [String: Int] = [:],
            averageDurationSeconds: Double? = nil
        ) {
            self.total = total
            self.byOutcome = byOutcome
            self.byMode = byMode
            self.errorsByKind = errorsByKind
            self.averageDurationSeconds = averageDurationSeconds
        }
    }

    public func summary(since: Date = .distantPast) throws -> Summary {
        let rows = try database.query(
            "SELECT outcome, mode, error_kind, duration_seconds FROM attempts WHERE created_at >= ?",
            [SQLiteValue(since.timeIntervalSince1970)]
        )
        var byOutcome: [AttemptRecord.Outcome: Int] = [:]
        var byMode: [Mode: Int] = [:]
        var errorsByKind: [String: Int] = [:]
        var durations: [Double] = []

        for row in rows {
            if let outcome = AttemptRecord.Outcome(rawValue: try row.text("outcome")) {
                byOutcome[outcome, default: 0] += 1
            }
            if let mode = Mode(rawValue: try row.text("mode")) {
                byMode[mode, default: 0] += 1
            }
            if let kind = row.optionalText("error_kind") {
                errorsByKind[kind, default: 0] += 1
            }
            if case .real(let value) = row.columns["duration_seconds"] {
                durations.append(value)
            } else if case .integer(let value) = row.columns["duration_seconds"] {
                durations.append(Double(value))
            }
        }

        return Summary(
            total: rows.count,
            byOutcome: byOutcome,
            byMode: byMode,
            errorsByKind: errorsByKind,
            averageDurationSeconds: durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count)
        )
    }

    /// As tentativas mais recentes que não deram certo, para inspeção manual.
    public func recentFailures(limit: Int = 20) throws -> [AttemptRecord] {
        let rows = try database.query(
            "SELECT * FROM attempts WHERE outcome IN ('error', 'blocked') ORDER BY created_at DESC LIMIT ?",
            [SQLiteValue(limit)]
        )
        return try rows.map(Self.record(from:))
    }

    private static func record(from row: SQLiteRow) throws -> AttemptRecord {
        var duration: Double?
        if case .real(let value) = row.columns["duration_seconds"] { duration = value }
        else if case .integer(let value) = row.columns["duration_seconds"] { duration = Double(value) }

        return AttemptRecord(
            timestamp: Date(timeIntervalSince1970: try row.real("created_at")),
            mode: Mode(rawValue: try row.text("mode")) ?? .research,
            model: try row.text("model"),
            caller: Caller(rawValue: try row.text("caller")) ?? .unknown,
            outcome: AttemptRecord.Outcome(rawValue: try row.text("outcome")) ?? .error,
            errorKind: row.optionalText("error_kind"),
            errorDetail: row.optionalText("error_detail"),
            durationSeconds: duration,
            responseCharacters: (try? row.int("response_characters")),
            truncated: (try? row.bool("truncated")) ?? false,
            hadWorkspace: (try? row.bool("had_workspace")) ?? false,
            hadAttachment: (try? row.bool("had_attachment")) ?? false
        )
    }
}
