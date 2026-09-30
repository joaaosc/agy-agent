import Foundation

/// Orquestra uma delegação: cache, chamada e persistência.
///
/// A divisão de responsabilidade aqui é o que protege o contexto de quem
/// chamou. O serviço decide **se** vale chamar o `agy`; o que ele devolve é
/// sempre um `Outcome` com a resposta já dentro do orçamento, mais metadados
/// que o chamador pode imprimir em stderr sem pagar contexto por eles.
public struct DelegationService: Sendable {
    public enum Origin: Sendable, Equatable {
        case cache
        case agy

        public var label: String {
            switch self {
            case .cache: "cache"
            case .agy: "agy"
            }
        }
    }

    public struct Outcome: Sendable {
        public var packet: EvidencePacket
        public var origin: Origin
        public var warnings: [String]

        public init(packet: EvidencePacket, origin: Origin, warnings: [String] = []) {
            self.packet = packet
            self.origin = origin
            self.warnings = warnings
        }
    }

    /// Política de cache de uma chamada.
    public enum CachePolicy: Sendable, Equatable {
        /// Lê e grava (padrão).
        case use
        /// Ignora o que está gravado, mas grava o resultado novo.
        case refresh
        /// Não lê nem grava. Para perguntas que não devem deixar rastro.
        case bypass
    }

    private let runner: AgyRunner
    private let cache: PacketStore?
    private let spendGuard: SpendGuard
    private let telemetry: TelemetryStore?

    public init(
        runner: AgyRunner,
        cache: PacketStore?,
        spendGuard: SpendGuard = SpendGuard(),
        telemetry: TelemetryStore? = nil
    ) {
        self.runner = runner
        self.cache = cache
        self.spendGuard = spendGuard
        self.telemetry = telemetry
    }

    public func delegate(
        _ request: DelegationRequest,
        maxCacheAge: Duration,
        policy: CachePolicy = .use
    ) throws -> Outcome {
        let request = try request.validated()
        let key = request.query.cacheKey

        if policy == .use, let cache, let packet = try cache.packet(forKey: key, maxAge: maxCacheAge) {
            if packet.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Versões anteriores aceitavam SUCCESS vazio. Não perpetuar
                // esse resultado inválido depois que o runner passou a falhar.
                try? cache.remove(key: key)
            } else {
                // O hit é contado mesmo que a gravação falhe depois: a métrica
                // mede chamadas evitadas, e a chamada já foi evitada.
                try? cache.recordHit(forKey: key)
                recordAttempt(request, outcome: .cache, packet: packet)
                return Outcome(packet: packet, origin: .cache)
            }
        }

        // O freio de gasto fica fora do do/catch de baixo de propósito: ele
        // já registra e lança o próprio erro, e não deve ser pego de novo
        // pelo catch que trata falhas do runner — isso duplicaria a linha.
        if case .blocked(let reason) = spendGuard.check(store: cache) {
            recordAttempt(request, outcome: .blocked, errorKind: "spend_limit", errorDetail: reason)
            throw AgyAgentError.spendLimitReached(reason)
        }

        do {
            let delegated = try runner.run(request)
            recordAttempt(request, outcome: .success, packet: delegated.packet)

            if policy != .bypass, let cache {
                do {
                    try cache.store(delegated.packet)
                } catch {
                    // Falhar a delegação inteira porque o cache não gravou seria
                    // trocar um problema pequeno por um grande: a resposta existe.
                    return Outcome(
                        packet: delegated.packet,
                        origin: .agy,
                        warnings: delegated.warnings + ["cache não gravado: \(error)"]
                    )
                }
            }
            return Outcome(packet: delegated.packet, origin: .agy, warnings: delegated.warnings)
        } catch {
            let kind = (error as? AgyAgentError)?.kindLabel ?? "unknown"
            recordAttempt(request, outcome: .error, errorKind: kind, errorDetail: Self.telemetryDetail(for: error))
            throw error
        }
    }

    /// Impede que stdout/stderr do backend entre no banco de telemetria. A
    /// mensagem completa continua disponível ao chamador no momento da falha.
    static func telemetryDetail(for error: any Error) -> String? {
        guard let error = error as? AgyAgentError else { return nil }
        return switch error {
        case .agyFailed(let status, _): "agy retornou status \(status)"
        case .malformedEnvelope: "saída do agy em formato inválido"
        case .emptyResponse: "agy terminou sem resposta"
        default: error.description
        }
    }

    /// Grava a tentativa; nunca deixa a telemetria interromper a delegação.
    private func recordAttempt(
        _ request: DelegationRequest,
        outcome: AttemptRecord.Outcome,
        packet: EvidencePacket? = nil,
        errorKind: String? = nil,
        errorDetail: String? = nil
    ) {
        guard let telemetry else { return }
        let record = AttemptRecord(
            mode: request.mode,
            model: request.model,
            caller: runner.caller,
            outcome: outcome,
            errorKind: errorKind,
            errorDetail: errorDetail,
            durationSeconds: packet?.durationSeconds,
            responseCharacters: packet?.responseCharacters,
            truncated: packet?.truncated ?? false,
            hadWorkspace: request.workspace != nil,
            hadAttachment: request.attachment != nil
        )
        try? telemetry.record(record)
    }
}
