import Foundation

/// Registro de uma tentativa de delegação, sucesso ou não.
///
/// `PacketStore` só grava o que deu certo — é uma memória de respostas, não
/// um diário de tentativas. Para saber onde a ferramenta está falhando (a
/// pergunta que motiva este arquivo), é preciso registrar **toda** tentativa,
/// inclusive as que não produziram pacote nenhum.
public struct AttemptRecord: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable, CaseIterable {
        /// Servida do cache; não chamou o agy.
        case cache
        case success
        case error
        /// Barrada pelo freio de gasto antes de sair.
        case blocked
    }

    public var timestamp: Date
    public var mode: Mode
    public var model: String
    public var caller: Caller
    public var outcome: Outcome
    /// `AgyAgentError.kindLabel`, quando `outcome` é `.error` ou `.blocked`.
    public var errorKind: String?
    /// Texto curto do erro. Cortado para não inflar o banco com stderr longo.
    public var errorDetail: String?
    /// `nil` para tentativas que não chegaram a chamar o agy (cache, bloqueio).
    public var durationSeconds: Double?
    public var responseCharacters: Int?
    public var truncated: Bool
    public var hadWorkspace: Bool
    public var hadAttachment: Bool

    public init(
        timestamp: Date = Date(),
        mode: Mode,
        model: String,
        caller: Caller,
        outcome: Outcome,
        errorKind: String? = nil,
        errorDetail: String? = nil,
        durationSeconds: Double? = nil,
        responseCharacters: Int? = nil,
        truncated: Bool = false,
        hadWorkspace: Bool = false,
        hadAttachment: Bool = false
    ) {
        self.timestamp = timestamp
        self.mode = mode
        self.model = model
        self.caller = caller
        self.outcome = outcome
        self.errorKind = errorKind
        // O detalhe existe para inspeção humana, não para reprocessar; 300
        // caracteres bastam para reconhecer o problema sem guardar despejos
        // inteiros de stderr.
        self.errorDetail = errorDetail.map { String($0.prefix(300)) }
        self.durationSeconds = durationSeconds
        self.responseCharacters = responseCharacters
        self.truncated = truncated
        self.hadWorkspace = hadWorkspace
        self.hadAttachment = hadAttachment
    }
}
