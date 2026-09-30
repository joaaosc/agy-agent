import Foundation

/// Leitor de um subconjunto plano de TOML.
///
/// O pacote não tem dependências externas e a configuração usada é simples:
/// pares `chave = valor` e tabelas de um nível (`[mode.research]`), com
/// string, inteiro e booleano. Um parser completo de TOML seria um grafo de
/// dependências desproporcional ao uso.
///
/// A regra que torna isso seguro é falhar em vez de ignorar: array, string
/// multilinha, data, float e tabela aninhada produzem erro com número de
/// linha. Um parser que aceitasse silenciosamente o que não entende faria a
/// configuração do usuário parecer aplicada sem estar.
public enum TOML {
    public enum Value: Sendable, Equatable {
        case string(String)
        case integer(Int)
        case boolean(Bool)

        public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
        public var intValue: Int? { if case .integer(let value) = self { value } else { nil } }
        public var boolValue: Bool? { if case .boolean(let value) = self { value } else { nil } }
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let line: Int
        public let reason: String

        public var description: String { "linha \(line): \(reason)" }
    }

    /// Tabelas indexadas pelo nome; a raiz é a chave vazia.
    public static func parse(_ text: String) throws -> [String: [String: Value]] {
        var tables: [String: [String: Value]] = [:]
        var current = ""

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = index + 1
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else {
                    throw ParseError(line: number, reason: "cabeçalho de tabela sem ] final")
                }
                guard !line.hasPrefix("[[") else {
                    throw ParseError(line: number, reason: "array de tabelas não é suportado")
                }
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else {
                    throw ParseError(line: number, reason: "nome de tabela vazio")
                }
                current = name
                tables[current] = tables[current] ?? [:]
                continue
            }

            guard let separator = line.firstIndex(of: "=") else {
                throw ParseError(line: number, reason: "esperado `chave = valor`")
            }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                throw ParseError(line: number, reason: "chave vazia")
            }
            guard !key.contains(".") else {
                throw ParseError(line: number, reason: "chave pontuada não é suportada; use uma tabela")
            }
            guard tables[current]?[key] == nil else {
                throw ParseError(line: number, reason: "chave `\(key)` duplicada em `\(current.isEmpty ? "raiz" : current)`")
            }
            tables[current, default: [:]][key] = try value(from: rawValue, line: number)
        }
        return tables
    }

    /// Remove comentário `#`, respeitando `#` dentro de string.
    static func stripComment(_ line: String) -> String {
        var inString = false
        var result = ""
        var previous: Character?
        for character in line {
            if character == "\"", previous != "\\" { inString.toggle() }
            if character == "#", !inString { break }
            result.append(character)
            previous = character
        }
        return result
    }

    static func value(from raw: String, line: Int) throws -> Value {
        guard !raw.isEmpty else {
            throw ParseError(line: line, reason: "valor ausente")
        }
        if raw.hasPrefix("\"\"\"") || raw.hasPrefix("'''") {
            throw ParseError(line: line, reason: "string multilinha não é suportada")
        }
        if raw.hasPrefix("[") || raw.hasPrefix("{") {
            throw ParseError(line: line, reason: "array e tabela inline não são suportados")
        }
        if raw.hasPrefix("\"") {
            guard raw.count >= 2, raw.hasSuffix("\"") else {
                throw ParseError(line: line, reason: "string sem aspas de fechamento")
            }
            return .string(unescape(String(raw.dropFirst().dropLast())))
        }
        if raw.hasPrefix("'") {
            guard raw.count >= 2, raw.hasSuffix("'") else {
                throw ParseError(line: line, reason: "string literal sem aspas de fechamento")
            }
            return .string(String(raw.dropFirst().dropLast()))
        }
        if raw == "true" { return .boolean(true) }
        if raw == "false" { return .boolean(false) }
        if let integer = Int(raw.replacingOccurrences(of: "_", with: "")) { return .integer(integer) }
        if Double(raw) != nil {
            throw ParseError(line: line, reason: "número decimal não é suportado; use inteiro")
        }
        throw ParseError(line: line, reason: "valor não reconhecido: `\(raw)`")
    }

    static func unescape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
