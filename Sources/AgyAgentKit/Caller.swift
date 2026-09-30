import Foundation

/// Quem chamou a ferramenta.
///
/// Gravado em cada pacote para responder a uma pergunta prática: a delegação
/// está mesmo sendo usada no Codex, ou só no Claude Code? Sem isso a única
/// forma de saber seria confiar na memória.
public enum Caller: String, Sendable, Codable, CaseIterable {
    case claudeCode = "claude-code"
    case codex
    case terminal
    case unknown

    public var label: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .terminal: "terminal"
        case .unknown: "desconhecido"
        }
    }

    /// Identifica o chamador pelas variáveis que cada ambiente exporta.
    public static func detect(environment: [String: String]) -> Caller {
        if environment["CLAUDECODE"] == "1" || environment["CLAUDE_CODE_ENTRYPOINT"] != nil {
            return .claudeCode
        }
        if environment.keys.contains(where: { $0.hasPrefix("CODEX_") }) {
            return .codex
        }
        // Um terminal comum tem TERM; um processo sem terminal nem isso.
        return environment["TERM"] != nil ? .terminal : .unknown
    }
}
