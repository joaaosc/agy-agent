import Foundation

/// Freio de gasto.
///
/// A ferramenta existe para poupar contexto de quem chama, mas ela própria
/// consome cota do Gemini. Sem limite, um laço mal escrito — ou um agente
/// insistente — faria dezenas de chamadas de 40 000 tokens sem ninguém
/// perceber até a cota acabar.
///
/// O freio age **antes** da chamada, com base no que já foi gasto na janela.
/// Recusar é barato; descobrir depois, não.
public struct SpendGuard: Sendable {
    public struct Limits: Sendable, Equatable {
        /// Máximo de chamadas ao `agy` na janela.
        public var maxCalls: Int
        /// Máximo de tokens consumidos no `agy` na janela.
        public var maxAgyTokens: Int
        /// Tamanho da janela.
        public var window: Duration

        public init(maxCalls: Int = 40, maxAgyTokens: Int = 2_000_000, window: Duration = .seconds(5 * 3600)) {
            self.maxCalls = maxCalls
            self.maxAgyTokens = maxAgyTokens
            self.window = window
        }

        /// Padrões deliberadamente folgados para uso normal e apertados o
        /// bastante para travar um laço acidental. Com ~40 000 tokens por
        /// chamada, 40 chamadas ≈ 1,6 milhão de tokens em cinco horas.
        public static let `default` = Limits()
    }

    public enum Verdict: Sendable, Equatable {
        case allowed(callsUsed: Int, tokensUsed: Int)
        case blocked(reason: String)

        public var isAllowed: Bool { if case .allowed = self { true } else { false } }
    }

    private let limits: Limits
    private let clock: @Sendable () -> Date

    public init(limits: Limits = .default, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.limits = limits
        self.clock = clock
    }

    /// Consulta o gasto da janela e decide se a próxima chamada pode sair.
    public func check(store: PacketStore?) -> Verdict {
        guard let store else { return .allowed(callsUsed: 0, tokensUsed: 0) }
        let since = clock().addingTimeInterval(-Double(limits.window.components.seconds))
        guard let summary = try? store.delegationSummary(since: since) else {
            // Sem leitura do histórico não há como frear com segurança; deixar
            // passar é o menor mal, porque bloquear tudo por falha de leitura
            // tornaria a ferramenta inutilizável.
            return .allowed(callsUsed: 0, tokensUsed: 0)
        }

        return check(
            callsUsed: summary.calls,
            tokensUsed: summary.agyInputTokens + summary.agyOutputTokens
        )
    }

    /// Aplica os mesmos limites a contadores reunidos de mais de um backend.
    /// Isso permite que rotas que registram telemetria fora do `PacketStore`
    /// compartilhem o mesmo teto de gasto.
    public func check(callsUsed: Int, tokensUsed: Int) -> Verdict {
        let boundedCalls = max(0, callsUsed)
        let boundedTokens = max(0, tokensUsed)
        let hours = limits.window.components.seconds / 3600
        if boundedCalls >= limits.maxCalls {
            return .blocked(reason: """
                limite de \(limits.maxCalls) chamadas em \(hours)h atingido (\(boundedCalls) usadas). \
                Aumente `max_calls_per_window` no config.toml ou espere a janela passar.
                """)
        }
        if boundedTokens >= limits.maxAgyTokens {
            return .blocked(reason: """
                limite de \(limits.maxAgyTokens) tokens do agy em \(hours)h atingido (\(boundedTokens) usados). \
                Aumente `max_agy_tokens_per_window` no config.toml ou espere a janela passar.
                """)
        }
        return .allowed(callsUsed: boundedCalls, tokensUsed: boundedTokens)
    }
}
