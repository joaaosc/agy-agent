import Foundation
import CryptoKit

/// Pergunta delegada ao agy, antes da execução.
///
/// É o insumo da chave de cache: dois `Query` iguais devem produzir a mesma
/// chave, e qualquer campo que altere a resposta precisa entrar no digest.
public struct Query: Sendable, Equatable, Codable {
    public var mode: Mode
    public var question: String
    public var model: String
    /// Raiz do workspace anexado, quando houver.
    public var workspaceRoot: String?
    /// Digest do prompt de sistema usado; editar o prompt invalida o cache.
    public var promptDigest: String
    /// Texto adicional colado na chamada (diff, arquivo, trecho).
    public var attachmentDigest: String?

    public init(
        mode: Mode,
        question: String,
        model: String,
        workspaceRoot: String? = nil,
        promptDigest: String,
        attachmentDigest: String? = nil
    ) {
        self.mode = mode
        self.question = question
        self.model = model
        self.workspaceRoot = workspaceRoot
        self.promptDigest = promptDigest
        self.attachmentDigest = attachmentDigest
    }

    /// Chave de cache estável. A ordem dos campos é fixa e explícita;
    /// depender da ordem de `Encodable` tornaria a chave frágil.
    public var cacheKey: String {
        let material = [
            "v\(EvidencePacket.schemaVersion)",
            mode.rawValue,
            model,
            workspaceRoot ?? "-",
            promptDigest,
            attachmentDigest ?? "-",
            Digest.normalize(question),
        ].joined(separator: "\u{1F}")
        return Digest.sha256(material)
    }
}

/// Resultado de uma delegação, com proveniência suficiente para ser reusado,
/// auditado ou invalidado sem repetir a chamada.
public struct EvidencePacket: Sendable, Equatable, Codable {
    public static let schemaVersion = 1

    public var id: UUID
    public var schemaVersion: Int
    public var cacheKey: String
    public var query: Query
    public var response: String
    public var conversationID: String?
    public var usage: AgyEnvelope.Usage
    public var durationSeconds: Double
    public var agyVersion: String
    public var createdAt: Date
    /// A resposta excedeu o orçamento e foi cortada na volta.
    public var truncated: Bool
    /// Quem pediu a delegação.
    public var caller: Caller

    /// Tamanho da resposta em caracteres — a medida que importa para o
    /// chamador, porque é o que entra no contexto dele.
    public var responseCharacters: Int { response.count }

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = EvidencePacket.schemaVersion,
        cacheKey: String,
        query: Query,
        response: String,
        conversationID: String? = nil,
        usage: AgyEnvelope.Usage = AgyEnvelope.Usage(),
        durationSeconds: Double = 0,
        agyVersion: String = "unknown",
        createdAt: Date = Date(),
        truncated: Bool = false,
        caller: Caller = .unknown
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.cacheKey = cacheKey
        self.query = query
        self.response = response
        self.conversationID = conversationID
        self.usage = usage
        self.durationSeconds = durationSeconds
        self.agyVersion = agyVersion
        self.createdAt = createdAt
        self.truncated = truncated
        self.caller = caller
    }

    public init(
        query: Query,
        envelope: AgyEnvelope,
        agyVersion: String,
        now: Date = Date(),
        budget: Int? = nil,
        caller: Caller = .unknown
    ) {
        let raw = envelope.response.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = ResponseBudget.apply(budget ?? query.mode.responseBudget, to: raw)
        self.init(
            cacheKey: query.cacheKey,
            query: query,
            response: trimmed.text,
            conversationID: envelope.conversationID,
            usage: envelope.usage,
            durationSeconds: envelope.durationSeconds,
            agyVersion: agyVersion,
            createdAt: now,
            truncated: trimmed.truncated,
            caller: caller
        )
    }

    /// Um pacote está fresco o bastante para ser servido do cache?
    ///
    /// Modos que dependem de busca na web envelhecem; modos que só leem
    /// material fornecido na própria chamada não envelhecem sozinhos —
    /// para eles, a invalidação vem da mudança do digest, não do relógio.
    public func isFresh(at now: Date, maxAge: Duration) -> Bool {
        guard query.mode.dependsOnWebSearch else { return true }
        let age = now.timeIntervalSince(createdAt)
        guard age >= 0 else { return false }
        return age <= Double(maxAge.components.seconds)
    }
}

public enum Digest {
    public static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    public static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Normaliza espaçamento para que diferenças cosméticas na pergunta
    /// não produzam entradas de cache distintas.
    public static func normalize(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}


/// Aplicação do orçamento de resposta.
///
/// Pedir brevidade no prompt não garante brevidade. O corte na volta é o que
/// protege o contexto de quem chamou, e ele precisa ser visível: uma resposta
/// silenciosamente cortada levaria a conclusões erradas.
public enum ResponseBudget {
    public static let truncationMarker = "\n\n[resposta cortada no orçamento de %d caracteres]"

    public static func apply(_ budget: Int, to text: String) -> (text: String, truncated: Bool) {
        guard budget > 0, text.count > budget else { return (text, false) }
        let marker = String(format: truncationMarker, budget)
        // O corte acontece em fronteira de parágrafo sempre que houver uma
        // razoavelmente perto do limite: cortar no meio de uma frase produz
        // afirmação incompleta, que é pior do que resposta curta.
        let hardLimit = text.index(text.startIndex, offsetBy: budget)
        let head = String(text[..<hardLimit])
        let cut = head.range(of: "\n\n", options: .backwards)
        let keepFrom = cut.map(\.lowerBound) ?? hardLimit
        let minimumKept = budget / 2
        let body = text.distance(from: text.startIndex, to: keepFrom) >= minimumKept
            ? String(text[..<keepFrom])
            : head
        return (body.trimmingCharacters(in: .whitespacesAndNewlines) + marker, true)
    }
}
