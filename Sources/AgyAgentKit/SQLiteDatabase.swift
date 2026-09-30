import Foundation
import SQLite3

/// Envoltório mínimo sobre `libsqlite3`.
///
/// O pacote não tem dependências externas; `SQLite3` vem no SDK. O escopo
/// aqui é deliberadamente pequeno: abrir, migrar, executar e ler linhas.
/// Nada de ORM.
final class SQLiteDatabase: @unchecked Sendable {
    /// `SQLITE_TRANSIENT`: o SQLite copia a string em vez de guardar o
    /// ponteiro. Sem isso, um `String` temporário seria lido depois de morto.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let handle: OpaquePointer
    private let lock = NSLock()

    let url: URL

    init(url: URL, busyTimeout: Duration = .seconds(10)) throws {
        self.url = url
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path(percentEncoded: false), &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            if let handle { sqlite3_close_v2(handle) }
            throw AgyAgentError.storeFailed("abrir \(url.lastPathComponent): \(message)")
        }
        self.handle = handle

        // O banco pode já existir com permissões herdadas de um processo
        // antigo. Restrinja o arquivo principal antes de ativar WAL; os
        // sidecars são restringidos novamente depois que o SQLite os cria.
        try Self.restrictPermissions(for: url)

        // WAL permite um escritor e vários leitores simultâneos. Duas sessões
        // (Codex e Claude Code) chamando a ferramenta ao mesmo tempo é o caso
        // normal, não a exceção.
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
        try Self.restrictPermissions(for: url)
        sqlite3_busy_timeout(handle, Int32(busyTimeout.components.seconds * 1000))
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "erro desconhecido"
            sqlite3_free(error)
            throw AgyAgentError.storeFailed(message)
        }
        try Self.restrictPermissions(for: url)
    }

    /// Executa uma instrução com parâmetros posicionais.
    func run(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw AgyAgentError.storeFailed("\(String(cString: sqlite3_errmsg(handle))) [\(sql)]")
        }
        try Self.restrictPermissions(for: url)
    }

    /// Lê todas as linhas de uma consulta.
    func query(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> [SQLiteRow] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        var rows: [SQLiteRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw AgyAgentError.storeFailed(String(cString: sqlite3_errmsg(handle)))
            }
            var columns: [String: SQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                columns[name] = value(of: statement, at: index)
            }
            rows.append(SQLiteRow(columns: columns))
        }
        return rows
    }

    /// Agrupa escritas numa única transação.
    ///
    /// Usada apenas para operações curtas. Nenhuma transação cobre a chamada
    /// ao `agy`: manter o banco travado por minutos bloquearia a outra sessão.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ parameters: [SQLiteValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AgyAgentError.storeFailed("\(String(cString: sqlite3_errmsg(handle))) [\(sql)]")
        }
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch parameter {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let value): sqlite3_bind_int64(statement, index, value)
            case .real(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, Self.transient)
            }
        }
        return statement
    }

    private func value(of statement: OpaquePointer?, at index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: .real(sqlite3_column_double(statement, index))
        case SQLITE_NULL: .null
        default:
            if let pointer = sqlite3_column_text(statement, index) {
                .text(String(cString: pointer))
            } else {
                .null
            }
        }
    }

    private static func restrictPermissions(for url: URL) throws {
        let manager = FileManager.default
        let paths = [url.path(percentEncoded: false),
                     url.path(percentEncoded: false) + "-wal",
                     url.path(percentEncoded: false) + "-shm"]
        for path in paths where manager.fileExists(atPath: path) {
            try manager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: path)
        }
    }
}

enum SQLiteValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    init(_ value: Int) { self = .integer(Int64(value)) }
    init(_ value: Double) { self = .real(value) }
    init(_ value: Bool) { self = .integer(value ? 1 : 0) }
}

struct SQLiteRow {
    let columns: [String: SQLiteValue]

    func text(_ name: String) throws -> String {
        guard case .text(let value) = columns[name] else {
            throw AgyAgentError.storeFailed("coluna \(name) não é texto")
        }
        return value
    }

    func optionalText(_ name: String) -> String? {
        if case .text(let value) = columns[name] { return value }
        return nil
    }

    func integer(_ name: String) throws -> Int64 {
        guard case .integer(let value) = columns[name] else {
            throw AgyAgentError.storeFailed("coluna \(name) não é inteiro")
        }
        return value
    }

    func int(_ name: String) throws -> Int { Int(try integer(name)) }

    func bool(_ name: String) throws -> Bool { try integer(name) != 0 }

    func real(_ name: String) throws -> Double {
        switch columns[name] {
        case .real(let value): value
        case .integer(let value): Double(value)
        default: throw AgyAgentError.storeFailed("coluna \(name) não é numérica")
        }
    }
}
