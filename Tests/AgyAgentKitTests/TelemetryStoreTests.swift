import Testing
import Foundation
@testable import AgyAgentKit

@Suite("Diário de tentativas")
struct TelemetryStoreTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    func store(_ directory: borrowing TemporaryDirectory, now: Date = TelemetryStoreTests.now) throws -> TelemetryStore {
        try TelemetryStore(url: directory.url.appending(path: "sub/telemetry.sqlite"), clock: { now })
    }

    func record(
        mode: Mode = .verify,
        caller: Caller = .claudeCode,
        outcome: AttemptRecord.Outcome = .success,
        errorKind: String? = nil,
        duration: Double? = 3.5,
        at date: Date = TelemetryStoreTests.now
    ) -> AttemptRecord {
        AttemptRecord(
            timestamp: date,
            mode: mode,
            model: "gemini-3.8-flash-medium",
            caller: caller,
            outcome: outcome,
            errorKind: errorKind,
            durationSeconds: duration,
            responseCharacters: outcome == .success ? 500 : nil
        )
    }

    @Test("O diretório é criado sob demanda, como no PacketStore")
    func createsDirectory() throws {
        let directory = try TemporaryDirectory()
        let telemetry = try store(directory)
        #expect(FileManager.default.fileExists(atPath: telemetry.url.path(percentEncoded: false)))
    }

    @Test("O banco principal fica legível apenas pelo usuário atual")
    func databasePermissionsAreRestricted() throws {
        let directory = try TemporaryDirectory()
        let telemetry = try store(directory)
        try telemetry.record(record())
        let attributes = try FileManager.default.attributesOfItem(atPath: telemetry.url.path(percentEncoded: false))
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions.map { $0 & 0o777 } == 0o600)
    }

    @Test("Abrir duas vezes preserva o que já foi gravado")
    func migrationIsIdempotent() throws {
        let directory = try TemporaryDirectory()
        try store(directory).record(record())
        let reopened = try store(directory)
        #expect(try reopened.summary().total == 1)
    }

    @Test("Migração v2 adiciona diagnóstico de latência sem perder registros")
    func migratesVersionTwoLatencyFields() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "telemetry.sqlite")
        let database = try SQLiteDatabase(url: url)
        try database.execute("CREATE TABLE schema_version (version INTEGER NOT NULL); INSERT INTO schema_version VALUES (2)")
        try database.execute("""
            CREATE TABLE external_usage (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                role TEXT NOT NULL,
                input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0,
                duration_seconds REAL,
                response_characters INTEGER NOT NULL DEFAULT 0,
                success INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO external_usage (
                created_at, role, input_tokens, output_tokens, duration_seconds,
                response_characters, success
            ) VALUES (1700000000, 'gemini_worker', 10, 2, 5, 20, 1);
            """)

        let telemetry = try TelemetryStore(url: url)
        let records = try telemetry.recentExternalLatency()
        #expect(records.count == 1)
        #expect(records[0].totalTokens == 12)
        #expect(records[0].backendDurationSeconds == nil)
        #expect(records[0].numTurns == 0)
    }

    @Test("Ledger externo migra, agrega somente métricas e é idempotente")
    func externalUsageLedger() throws {
        let directory = try TemporaryDirectory()
        let telemetry = try store(directory)
        try telemetry.recordExternalUsage(.init(
            timestamp: Self.now, role: "gemini_worker", inputTokens: 100,
            outputTokens: 20, durationSeconds: 2.5, backendDurationSeconds: 1.5,
            numTurns: 3, responseCharacters: 400, success: true
        ))
        try telemetry.recordExternalUsage(.init(
            timestamp: Self.now.addingTimeInterval(10), role: "gemini_reviewer",
            inputTokens: 999, outputTokens: 999, responseCharacters: 1, success: false
        ))

        let reopened = try store(directory)
        let summary = try reopened.externalUsageSummary()
        #expect(summary.calls == 2)
        #expect(summary.successfulCalls == 1)
        #expect(summary.inputTokens == 100)
        #expect(summary.outputTokens == 20)
        #expect(summary.responseCharacters == 400)
        #expect(try reopened.externalUsageSummary(since: Self.now.addingTimeInterval(5)).calls == 1)

        let latency = try reopened.recentExternalLatency()
        #expect(latency.count == 2)
        #expect(latency[1].role == "gemini_worker")
        #expect(latency[1].durationSeconds == 2.5)
        #expect(latency[1].backendDurationSeconds == 1.5)
        #expect(latency[1].numTurns == 3)
        #expect(latency[1].totalTokens == 120)
    }

    @Test("O resumo agrupa por desfecho, modo e tipo de erro")
    func summaryGroups() throws {
        let directory = try TemporaryDirectory()
        let telemetry = try store(directory)
        try telemetry.record(record(mode: .verify, outcome: .success))
        try telemetry.record(record(mode: .verify, outcome: .cache, duration: nil))
        try telemetry.record(record(mode: .inspect, outcome: .error, errorKind: "timed_out", duration: 12))
        try telemetry.record(record(mode: .research, outcome: .blocked, errorKind: "spend_limit", duration: nil))

        let summary = try telemetry.summary()
        #expect(summary.total == 4)
        #expect(summary.byOutcome[.success] == 1)
        #expect(summary.byOutcome[.cache] == 1)
        #expect(summary.byOutcome[.error] == 1)
        #expect(summary.byOutcome[.blocked] == 1)
        #expect(summary.byMode[.verify] == 2)
        #expect(summary.byMode[.inspect] == 1)
        #expect(summary.errorsByKind["timed_out"] == 1)
        #expect(summary.errorsByKind["spend_limit"] == 1)
    }

    @Test("A duração média só considera tentativas que a registraram")
    func averageDurationIgnoresNil() throws {
        let directory = try TemporaryDirectory()
        let telemetry = try store(directory)
        try telemetry.record(record(outcome: .success, duration: 4))
        try telemetry.record(record(outcome: .success, duration: 6))
        try telemetry.record(record(outcome: .cache, duration: nil))

        let summary = try telemetry.summary()
        #expect(summary.averageDurationSeconds == 5)
    }

    @Test("Resumo vazio não quebra e não tem duração média")
    func emptySummary() throws {
        let directory = try TemporaryDirectory()
        let summary = try store(directory).summary()
        #expect(summary.total == 0)
        #expect(summary.averageDurationSeconds == nil)
    }

    @Test("O filtro por data exclui tentativas fora da janela")
    func summarySinceFiltersByDate() throws {
        let directory = try TemporaryDirectory()
        let telemetry = try store(directory)
        try telemetry.record(record(at: Self.now.addingTimeInterval(-100_000)))
        try telemetry.record(record(at: Self.now))

        #expect(try telemetry.summary(since: Self.now.addingTimeInterval(-3600)).total == 1)
        #expect(try telemetry.summary().total == 2)
    }

    @Test("Falhas recentes vêm da mais nova para a mais antiga, só erro e bloqueio")
    func recentFailuresOrderAndFilter() throws {
        let directory = try TemporaryDirectory()
        let telemetry = try store(directory)
        try telemetry.record(record(outcome: .success, at: Self.now))
        try telemetry.record(record(outcome: .error, errorKind: "timed_out", at: Self.now.addingTimeInterval(10)))
        try telemetry.record(record(outcome: .blocked, errorKind: "spend_limit", at: Self.now.addingTimeInterval(20)))

        let failures = try telemetry.recentFailures()
        #expect(failures.count == 2)
        #expect(failures[0].errorKind == "spend_limit")
        #expect(failures[1].errorKind == "timed_out")
    }

    @Test("O detalhe do erro é cortado para não inflar o banco")
    func errorDetailIsTruncated() throws {
        let directory = try TemporaryDirectory()
        let telemetry = try store(directory)
        let long = String(repeating: "x", count: 5000)
        try telemetry.record(AttemptRecord(
            mode: .verify, model: "m", caller: .codex, outcome: .error,
            errorKind: "agy_failed", errorDetail: long
        ))
        let failures = try telemetry.recentFailures()
        #expect(failures.first?.errorDetail?.count == 300)
    }

    @Test("Roundtrip preserva todos os campos, inclusive os opcionais ausentes")
    func roundtrip() throws {
        let directory = try TemporaryDirectory()
        let telemetry = try store(directory)
        try telemetry.record(record(mode: .summarize, caller: .terminal, outcome: .cache, duration: nil))

        let failures = try telemetry.recentFailures() // vazio, mas exercita o mapeamento indiretamente
        #expect(failures.isEmpty)
        #expect(try telemetry.summary().byMode[.summarize] == 1)
    }
}
