import Foundation

public enum AgyAgentError: Error, Equatable, Sendable {
    /// `agy` não foi encontrado no PATH nem no caminho configurado.
    case agyNotFound(String)
    /// A saída do `agy` não continha um envelope JSON decodificável.
    case malformedEnvelope(String)
    /// O `agy` retornou status diferente de SUCCESS.
    case agyFailed(status: String, output: String)
    /// A chamada excedeu o tempo máximo configurado.
    case timedOut(seconds: Double)
    /// O modo exige workspace e nenhum diretório válido foi resolvido.
    case workspaceRequired(Mode)
    /// Pergunta vazia.
    case emptyQuestion
    /// O processo terminou sem produzir uma resposta utilizável.
    case emptyResponse(String)
    /// Identificador de conversa fora do formato que o `agy` emite.
    case invalidConversationID(String)
    /// O orçamento de resposta ultrapassa o limite de segurança.
    case invalidResponseBudget(requested: Int, maximum: Int)
    /// Arquivo de prompt ausente para o modo.
    case missingPrompt(Mode, URL)
    /// Falha de persistência (abrir, migrar, ler ou escrever no SQLite).
    case storeFailed(String)
    /// `config.toml` inválido ou com chave não reconhecida.
    case invalidConfiguration(String)
    /// O freio de gasto barrou a chamada antes de ela sair.
    case spendLimitReached(String)
    /// O processo não pôde ser lançado por outro motivo que não o executável
    /// ausente — tipicamente diretório de trabalho inexistente.
    case processLaunchFailed(executable: String, reason: String)
}

extension AgyAgentError {
    /// Rótulo curto e estável, para agregação em métricas.
    ///
    /// `description` é texto livre e pode mudar; um painel que agrupasse por
    /// ele quebraria a cada ajuste de mensagem. Este rótulo é o nome do caso,
    /// e só muda se o caso mudar.
    public var kindLabel: String {
        switch self {
        case .agyNotFound: "agy_not_found"
        case .malformedEnvelope: "malformed_envelope"
        case .agyFailed: "agy_failed"
        case .timedOut: "timed_out"
        case .workspaceRequired: "workspace_required"
        case .emptyQuestion: "empty_question"
        case .emptyResponse: "empty_response"
        case .invalidConversationID: "invalid_conversation_id"
        case .invalidResponseBudget: "invalid_response_budget"
        case .missingPrompt: "missing_prompt"
        case .storeFailed: "store_failed"
        case .invalidConfiguration: "invalid_configuration"
        case .spendLimitReached: "spend_limit"
        case .processLaunchFailed: "process_launch_failed"
        }
    }
}

extension AgyAgentError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .agyNotFound(let path):
            "agy não encontrado em \(path)"
        case .malformedEnvelope(let output):
            "saída do agy não contém envelope JSON válido: \(Self.truncated(output))"
        case .agyFailed(let status, let output):
            // O detalhe é o que de fato ajuda a diagnosticar (autenticação
            // expirada, cota excedida...); sem ele, a mensagem dizia apenas
            // "status X" e escondia a causa em todo lugar que a imprimisse.
            output.isEmpty
                ? "agy retornou status \(status)"
                : "agy retornou status \(status): \(Self.truncated(output))"
        case .timedOut(let seconds):
            "chamada excedeu \(seconds)s"
        case .workspaceRequired(let mode):
            "modo \(mode.rawValue) exige um workspace resolvível"
        case .emptyQuestion:
            "pergunta vazia"
        case .invalidConversationID(let value):
            "identificador de conversa inválido: `\(value)`"
        case .emptyResponse(let detail):
            detail.isEmpty
                ? "agy terminou sem resposta"
                : "agy terminou sem resposta: \(Self.truncated(detail))"
        case .invalidResponseBudget(let requested, let maximum):
            "orçamento de resposta inválido: \(requested) caracteres (máximo: \(maximum))"
        case .missingPrompt(let mode, let url):
            "prompt do modo \(mode.rawValue) ausente em \(url.path(percentEncoded: false))"
        case .storeFailed(let detail):
            "falha de persistência: \(detail)"
        case .invalidConfiguration(let detail):
            "configuração inválida: \(detail)"
        case .spendLimitReached(let reason):
            "freio de gasto: \(reason)"
        case .processLaunchFailed(let executable, let reason):
            "não foi possível lançar \(executable): \(reason)"
        }
    }

    /// Corta texto longo (stderr do agy pode ser um despejo grande) mantendo
    /// a mensagem de erro legível num terminal.
    private static func truncated(_ text: String, limit: Int = 500) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }
}
