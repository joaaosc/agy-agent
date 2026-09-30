import Foundation

/// Contabilidade de economia de contexto.
///
/// O relatório separa deliberadamente três grandezas que costumam ser
/// confundidas numa só:
///
/// 1. **O que a delegação custou a você** — exato. É o texto que entrou no
///    contexto de quem chamou: `response_characters`, convertido a token por
///    uma razão declarada.
/// 2. **O que foi deslocado para o Gemini** — exato do lado de lá, mas é um
///    *limite superior* da economia, não a economia. Nem todo token que o
///    Gemini leu teria sido lido aqui.
/// 3. **O que o cache dispensou** — exato. Respostas idênticas servidas sem
///    nova chamada.
///
/// Apresentar (2) como "economia" seria propaganda. O número honesto para
/// decidir se a ferramenta vale a pena é a razão entre (2) e (1): quanto
/// trabalho cada token gasto aqui comprou lá.
public struct SavingsReport: Sendable {
    /// Custo fixo de uma chamada ao `agy`, medido com um prompt trivial
    /// (`"Reply with exactly: OK"` → 24 809 tokens de entrada). Descontado do
    /// material lido para não creditar à delegação o overhead do próprio
    /// `agy`.
    public static let agyBaselineInputTokens = 24_800

    /// Caracteres por token. Aproximação usual para texto latino; o
    /// tokenizador do chamador não está disponível aqui, e por isso todo
    /// número derivado desta razão é rotulado como estimativa.
    public static let charactersPerToken = 4

    public struct Delegation: Sendable, Equatable {
        public var calls: Int
        public var cacheHits: Int
        public var responseCharacters: Int
        public var charactersFromCache: Int
        public var agyInputTokens: Int
        public var agyOutputTokens: Int

        /// Total de tokens observados no executor externo.
        public var externalTokens: Int { agyInputTokens + agyOutputTokens }

        /// Estimativa do que a delegação custou no contexto de quem chamou.
        public var estimatedLocalCost: Int { responseCharacters / SavingsReport.charactersPerToken }

        /// Estimativa do que o cache poupou no contexto de quem chamou.
        public var estimatedCacheSaving: Int { charactersFromCache / SavingsReport.charactersPerToken }

        /// Trabalho processado no Gemini, descontado o overhead fixo por
        /// chamada. Limite superior do que teria custado aqui.
        public var displacedTokens: Int {
            max(0, agyInputTokens - calls * SavingsReport.agyBaselineInputTokens) + agyOutputTokens
        }

        /// Quantos tokens de trabalho lá cada token gasto aqui comprou.
        public var leverage: Double {
            let local = estimatedLocalCost
            guard local > 0 else { return 0 }
            return Double(displacedTokens) / Double(local)
        }

        public init(
            calls: Int = 0,
            cacheHits: Int = 0,
            responseCharacters: Int = 0,
            charactersFromCache: Int = 0,
            agyInputTokens: Int = 0,
            agyOutputTokens: Int = 0
        ) {
            self.calls = calls
            self.cacheHits = cacheHits
            self.responseCharacters = responseCharacters
            self.charactersFromCache = charactersFromCache
            self.agyInputTokens = agyInputTokens
            self.agyOutputTokens = agyOutputTokens
        }

        public func adding(_ other: Delegation) -> Delegation {
            Delegation(
                calls: calls + other.calls,
                cacheHits: cacheHits + other.cacheHits,
                responseCharacters: responseCharacters + other.responseCharacters,
                charactersFromCache: charactersFromCache + other.charactersFromCache,
                agyInputTokens: agyInputTokens + other.agyInputTokens,
                agyOutputTokens: agyOutputTokens + other.agyOutputTokens
            )
        }
    }

    public var window: UsageWindow.Result
    public var delegation: Delegation
    public var windowLength: Duration

    public init(window: UsageWindow.Result, delegation: Delegation, windowLength: Duration) {
        self.window = window
        self.delegation = delegation
        self.windowLength = windowLength
    }

    /// Percentual de uma grandeza sobre o consumo real da janela.
    ///
    /// A base é o consumo **observado**, não uma cota: o teto da janela de 5 h
    /// não é um número publicado, e inventá-lo daria uma porcentagem falsa.
    public func percentOfWindow(_ tokens: Int) -> Double? {
        let base = window.total.billable
        guard base > 0 else { return nil }
        return Double(tokens) * 100 / Double(base)
    }

    public var fiveHourUsedPercent: Double? {
        guard let snapshot = window.rateLimits?.primary,
              snapshot.windowMinutes == 300,
              snapshot.isCurrent(at: window.end) else { return nil }
        return min(100, max(0, snapshot.usedPercent))
    }

    public var activeRateLimitWindowStart: Date? {
        guard fiveHourUsedPercent != nil else { return nil }
        return window.activeRateLimitWindowStart
    }

    public var fiveHourRemainingPercent: Double? {
        guard let used = fiveHourUsedPercent else { return nil }
        return max(0, 100 - used)
    }

    /// Percentual estimado a partir dos tokens observados por ponto percentual
    /// do snapshot local. Sem snapshot, o relatório não inventa uma cota.
    public func estimatedSavingsPercent(_ tokens: Int) -> Double? {
        guard let used = fiveHourUsedPercent, used > 0,
              let codexObserved = window.bySource[.codex]?.billable,
              codexObserved > 0 else { return nil }
        let observedPerPoint = Double(codexObserved) / used
        return Double(max(0, tokens)) / observedPerPoint
    }

    /// Tempo até a janela expirar, contado do primeiro turno encontrado.
    ///
    /// Sem nenhum turno na janela, não há o que expirar: a janela inteira
    /// está livre.
    public var remaining: Duration {
        let total = Double(windowLength.components.seconds)
        guard let anchor = window.firstTurn else { return .seconds(Int(total)) }
        let elapsed = Date().timeIntervalSince(anchor)
        return .seconds(Int(max(0, total - elapsed)))
    }

    /// Fração da janela já decorrida desde o primeiro turno.
    public var elapsedFraction: Double {
        let total = Double(windowLength.components.seconds)
        guard let anchor = window.firstTurn, total > 0 else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(anchor) / total))
    }
}
