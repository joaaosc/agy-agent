import Foundation

/// Consumo de tokens dos agentes que chamam esta ferramenta, lido dos
/// transcritos que eles já gravam em disco.
///
/// Nada aqui fala com modelo nenhum: são arquivos locais. É por isso que
/// acompanhar o consumo em tempo real, num segundo terminal, **não custa
/// token algum** — quem custa é a sessão do agente, não quem lê o arquivo.
///
/// - Claude Code: `~/.claude/projects/<slug>/<sessão>.jsonl`, uma linha por
///   mensagem, com `message.usage` e `timestamp`.
/// - Codex: `~/.codex/sessions/<ano>/<mês>/<dia>/rollout-*.jsonl`, registros
///   `token_usage_record` com `payload.usage` e `timestamp`.
public struct UsageWindow: Sendable {
    public enum Source: String, Sendable, CaseIterable {
        case claudeCode = "Claude Code"
        case codex = "Codex"
    }

    public struct Consumption: Sendable, Equatable {
        /// Entrada nova mais escrita de cache. É o que de fato foi processado.
        public var freshInputTokens: Int
        /// Leitura de cache: processada, porém muito mais barata.
        public var cachedInputTokens: Int
        public var outputTokens: Int
        public var turns: Int

        public var total: Int { freshInputTokens + cachedInputTokens + outputTokens }
        /// Aproximação do que pesa numa janela de uso, sem a leitura de cache.
        public var billable: Int { freshInputTokens + outputTokens }

        public init(freshInputTokens: Int = 0, cachedInputTokens: Int = 0, outputTokens: Int = 0, turns: Int = 0) {
            self.freshInputTokens = freshInputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.turns = turns
        }

        static func + (lhs: Consumption, rhs: Consumption) -> Consumption {
            Consumption(
                freshInputTokens: lhs.freshInputTokens + rhs.freshInputTokens,
                cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
                outputTokens: lhs.outputTokens + rhs.outputTokens,
                turns: lhs.turns + rhs.turns
            )
        }
    }

    /// Snapshot local do limite de uso reportado pelo provedor.
    public struct RateLimitSnapshot: Sendable, Equatable {
        public var usedPercent: Double
        public var windowMinutes: Int
        public var resetsAt: Date?
        public var timestamp: Date

        public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date?, timestamp: Date) {
            self.usedPercent = usedPercent
            self.windowMinutes = windowMinutes
            self.resetsAt = resetsAt
            self.timestamp = timestamp
        }

        /// Início da janela associado ao reset informado pelo provedor.
        public var windowStart: Date? {
            resetsAt?.addingTimeInterval(-Double(windowMinutes * 60))
        }

        public func isCurrent(at date: Date) -> Bool {
            guard let resetsAt else { return true }
            return resetsAt > date
        }
    }

    public struct RateLimits: Sendable, Equatable {
        public var primary: RateLimitSnapshot?
        public var secondary: RateLimitSnapshot?
        public var timestamp: Date

        public init(primary: RateLimitSnapshot?, secondary: RateLimitSnapshot?, timestamp: Date) {
            self.primary = primary
            self.secondary = secondary
            self.timestamp = timestamp
        }
    }

    public struct Result: Sendable {
        public var start: Date
        public var end: Date
        public var bySource: [Source: Consumption]
        /// Arquivos que não puderam ser lidos; reportados em vez de escondidos.
        public var unreadableFiles: [String]
        /// Primeiro turno encontrado na janela.
        ///
        /// A janela de uso não é um bloco fixo do relógio: ela começa no
        /// primeiro uso e expira cinco horas depois. Ancorar aqui torna o
        /// "restam" uma informação real em vez de decorativa.
        public var firstTurn: Date?
        /// Primeiro turno encontrado na janela, separado por fonte.
        ///
        /// O valor global permanece por compatibilidade; esta versão permite
        /// ancorar a janela local de cada transcript sem misturar fontes.
        public var firstTurnBySource: [Source: Date]
        /// Snapshot mais recente de `rate_limits` encontrado no transcript local.
        public var rateLimits: RateLimits?

        /// Início da janela ativa quando o snapshot local ainda é válido.
        public var activeRateLimitWindowStart: Date? {
            guard let primary = rateLimits?.primary,
                  primary.windowMinutes == 300,
                  primary.isCurrent(at: end) else { return nil }
            return primary.windowStart
        }

        public init(
            start: Date,
            end: Date,
            bySource: [Source: Consumption],
            unreadableFiles: [String],
            firstTurn: Date?,
            rateLimits: RateLimits? = nil,
            firstTurnBySource: [Source: Date] = [:]
        ) {
            self.start = start
            self.end = end
            self.bySource = bySource
            self.unreadableFiles = unreadableFiles
            self.firstTurn = firstTurn
            self.firstTurnBySource = firstTurnBySource
            self.rateLimits = rateLimits
        }

        public var total: Consumption {
            bySource.values.reduce(Consumption(), +)
        }
    }

    private let claudeProjects: URL
    private let codexSessions: URL

    public init(homeDirectory: URL) {
        let home = DirectoryURL.normalized(homeDirectory)
        claudeProjects = home.appending(path: ".claude/projects")
        codexSessions = home.appending(path: ".codex/sessions")
    }

    /// Consumo entre `start` e `end`.
    ///
    /// Só abre arquivos modificados depois de `start`: uma sessão encerrada
    /// ontem não pode conter turno de hoje, e a pasta acumula centenas deles.
    public func consumption(from start: Date, to end: Date = Date()) -> Result {
        var bySource: [Source: Consumption] = [:]
        var unreadable: [String] = []
        var firstTurn: Date?
        var firstTurnBySource: [Source: Date] = [:]
        var latestRateLimits: RateLimits?
        var codexEvents: [(Date, Consumption)] = []

        for (source, root, parse) in [
            (Source.claudeCode, claudeProjects, Self.parseClaudeLine),
            (Source.codex, codexSessions, Self.parseCodexLine),
        ] as [(Source, URL, (Data) -> (Date, Consumption)?)] {
            var total = Consumption()
            for file in Self.transcripts(under: root, modifiedAfter: start) {
                let readResult = Self.readLines(from: file) { line in
                    if source == .codex,
                       let snapshot = Self.parseCodexRateLimitsLine(line),
                       snapshot.timestamp >= start, snapshot.timestamp <= end,
                       latestRateLimits == nil || snapshot.timestamp > latestRateLimits!.timestamp {
                        latestRateLimits = snapshot
                    }
                    guard let (date, consumption) = parse(line) else { return }
                    if source == .codex, date >= start, date <= end {
                        codexEvents.append((date, consumption))
                    }
                    guard date >= start, date <= end else { return }
                    if firstTurn == nil || date < firstTurn! { firstTurn = date }
                    if firstTurnBySource[source] == nil || date < firstTurnBySource[source]! {
                        firstTurnBySource[source] = date
                    }
                    total = total + consumption
                }
                if !readResult.completed { unreadable.append(file.path(percentEncoded: false)) }
            }
            bySource[source] = total
        }

        if bySource[.codex] != nil {
            let activeStart: Date
            if let primary = latestRateLimits?.primary,
               primary.windowMinutes == 300,
               primary.isCurrent(at: end) {
                activeStart = primary.windowStart ?? start
            } else {
                activeStart = start
            }
            bySource[.codex] = codexEvents
                .filter { $0.0 >= activeStart && $0.0 <= end }
                .map(\.1)
                .reduce(Consumption(), +)
        }

        return Result(
            start: start,
            end: end,
            bySource: bySource,
            unreadableFiles: unreadable,
            firstTurn: firstTurn,
            rateLimits: latestRateLimits,
            firstTurnBySource: firstTurnBySource
        )
    }

    static func transcripts(under root: URL, modifiedAfter: Date) -> [URL] {
        let root = DirectoryURL.normalized(root)
        guard let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        ) else { return [] }

        var files: [URL] = []
        let rootPath = root.path(percentEncoded: false).hasSuffix("/")
            ? root.path(percentEncoded: false)
            : root.path(percentEncoded: false) + "/"
        for case let url as URL in enumerator {
            guard url.standardizedFileURL.path(percentEncoded: false).hasPrefix(rootPath),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard url.pathExtension == "jsonl",
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= modifiedAfter else { continue }
            files.append(url)
        }
        return files
    }

    private struct LineReadResult {
        var completed: Bool
    }

    private static let maximumLineBytes = 1_048_576
    private static let maximumFileBytes = 64 * 1_024 * 1_024

    /// Lê JSONL em blocos para limitar memória em transcripts malformados.
    private static func readLines(from file: URL, _ consume: (Data) -> Void) -> LineReadResult {
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var line = Data()
            var bytesRead = 0
            var completed = true
            var discardingOversizedLine = false
            while true {
                let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
                if chunk.isEmpty { break }
                bytesRead += chunk.count
                if bytesRead > maximumFileBytes { completed = false; break }
                var start = chunk.startIndex
                while start < chunk.endIndex {
                    guard let newline = chunk[start...].firstIndex(of: 0x0A) else {
                        if !discardingOversizedLine,
                           line.count + chunk.distance(from: start, to: chunk.endIndex) <= maximumLineBytes {
                            line.append(contentsOf: chunk[start...])
                        } else {
                            line.removeAll(keepingCapacity: false)
                            discardingOversizedLine = true
                        }
                        break
                    }
                    let segment = chunk[start..<newline]
                    if !discardingOversizedLine && line.count + segment.count <= maximumLineBytes {
                        line.append(contentsOf: segment)
                        if !line.isEmpty { consume(line) }
                    }
                    line.removeAll(keepingCapacity: false)
                    discardingOversizedLine = false
                    start = chunk.index(after: newline)
                }
            }
            if !discardingOversizedLine && !line.isEmpty && line.count <= maximumLineBytes { consume(line) }
            return LineReadResult(completed: completed)
        } catch {
            return LineReadResult(completed: false)
        }
    }

    /// `ISO8601DateFormatter` não é `Sendable`; criar um por chamada é o
    /// preço de manter a análise livre de estado compartilhado. O custo é
    /// irrelevante ao lado da leitura dos arquivos.
    static func date(from text: String?) -> Date? {
        guard let text else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func parseClaudeLine(_ data: Data) -> (Date, Consumption)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let date = date(from: object["timestamp"] as? String) else { return nil }

        let input = usage["input_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        return (date, Consumption(
            freshInputTokens: input + cacheCreation,
            cachedInputTokens: cacheRead,
            outputTokens: output,
            turns: 1
        ))
    }

    static func parseCodexLine(_ data: Data) -> (Date, Consumption)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "token_usage_record",
              let payload = object["payload"] as? [String: Any],
              let usage = payload["usage"] as? [String: Any],
              let date = date(from: object["timestamp"] as? String) else { return nil }

        let input = usage["input_tokens"] as? Int ?? 0
        let cached = usage["cached_input_tokens"] as? Int ?? 0
        let cacheWrite = usage["cache_write_input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        // `input_tokens` do Codex já inclui a parte lida do cache.
        return (date, Consumption(
            freshInputTokens: max(0, input - cached) + cacheWrite,
            cachedInputTokens: cached,
            outputTokens: output,
            turns: 1
        ))
    }

    static func parseCodexRateLimitsLine(_ data: Data) -> RateLimits? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let timestamp = date(from: object["timestamp"] as? String),
              let limits = (payload["rate_limits"] as? [String: Any])
                ?? (payload["info"] as? [String: Any])?["rate_limits"] as? [String: Any] else { return nil }

        func parse(_ value: Any?) -> RateLimitSnapshot? {
            guard let dictionary = value as? [String: Any],
                  let used = (dictionary["used_percent"] as? NSNumber)?.doubleValue,
                  let window = (dictionary["window_minutes"] as? NSNumber)?.intValue else { return nil }
            let resetsAt: Date?
            if let seconds = (dictionary["resets_at"] as? NSNumber)?.doubleValue {
                resetsAt = Date(timeIntervalSince1970: seconds)
            } else {
                resetsAt = date(from: dictionary["resets_at"] as? String)
            }
            return RateLimitSnapshot(usedPercent: used, windowMinutes: window, resetsAt: resetsAt, timestamp: timestamp)
        }

        let primary = parse(limits["primary"])
        let secondary = parse(limits["secondary"])
        guard primary != nil || secondary != nil else { return nil }
        return RateLimits(primary: primary, secondary: secondary, timestamp: timestamp)
    }
}
