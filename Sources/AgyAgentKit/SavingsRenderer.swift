import Foundation

/// Desenho do relatório de economia.
///
/// O objetivo é ser didático sem ser desonesto: cada número vem rotulado com
/// o que ele é — medida, estimativa ou limite superior. Um painel que
/// mostrasse só "você economizou 600 mil tokens" seria bonito e falso.
public enum SavingsRenderer {
    /// Painel enxuto: gasto da janela em tokens e em percentual, e nada mais.
    ///
    /// Existe porque o relatório completo responde a perguntas de projeto, e
    /// o uso diário tem uma pergunta só: quanto já gastei e quanto a
    /// delegação me poupou. Tudo o que não serve a isso fica de fora.
    public static func renderCompact(
        _ report: SavingsReport,
        callers: [Caller: Int],
        limits: SpendGuard.Limits
    ) -> String {
        let window = report.window
        let delegation = report.delegation
        var lines: [String] = []

        func bar(_ fraction: Double, width: Int = 28) -> String {
            let filled = min(width, max(0, Int(fraction * Double(width))))
            return "[" + String(repeating: "█", count: filled)
                + String(repeating: "·", count: width - filled) + "]"
        }

        let anchor = window.firstTurn.map { "desde \(time($0))" } ?? "sem uso"
        lines.append("USO LOCAL 5H \(bar(report.elapsedFraction)) \(anchor) · restam \(clock(Double(report.remaining.components.seconds)))")
        if let snapshot = window.rateLimits?.primary, report.fiveHourUsedPercent != nil {
            let used = String(format: "%.1f", report.fiveHourUsedPercent!).replacingOccurrences(of: ".", with: ",")
            let remaining = String(format: "%.1f", report.fiveHourRemainingPercent!).replacingOccurrences(of: ".", with: ",")
            let reset = snapshot.resetsAt.map { " · reset \(time($0))" } ?? ""
            lines.append("LIMITE CODEX 5H  \(used)% usado · \(remaining)% restante\(reset)")
        } else {
            lines.append("LIMITE CODEX 5H  indisponível no transcript local")
        }
        lines.append("")

        for source in UsageWindow.Source.allCases {
            let consumption = window.bySource[source] ?? UsageWindow.Consumption()
            let share = window.total.billable > 0
                ? Double(consumption.billable) * 100 / Double(window.total.billable)
                : 0
            let name = source.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
            let tokens = pad(number(consumption.billable), 11)
            lines.append("  \(name)\(tokens)  \(String(format: "%5.1f", share).replacingOccurrences(of: ".", with: ","))%  \(consumption.turns) turnos")
        }
        lines.append("  \("TOTAL".padding(toLength: 13, withPad: " ", startingAt: 0))\(pad(number(window.total.billable), 11))   100,0%")
        lines.append("")

        lines.append("DELEGAÇÃO")
        let cost = delegation.estimatedLocalCost
        lines.append("  tokens externos\(pad(number(delegation.externalTokens), 11))  medida do executor")
        lines.append("  custou a você\(pad(number(cost), 11))  \(percentLabel(report.percentOfWindow(cost)))")
        let estimatedSavings = report.estimatedSavingsPercent(delegation.displacedTokens)
        let savingsNote = estimatedSavings.map { "\(decimal($0))% da cota de 5h (estimativa)" } ?? "percentual estimado indisponível"
        lines.append("  poupou (est.)\(pad(number(delegation.displacedTokens), 11))  \(savingsNote)")
        if delegation.calls > 0 {
            lines.append("  alavancagem  \(pad(String(format: "%.0f×", delegation.leverage), 11))  cada token daqui rendeu isso lá")
        }
        lines.append("")

        lines.append("CHAMADAS  \(delegation.calls)/\(limits.maxCalls) na janela  ·  \(delegation.cacheHits) do cache")
        let used = delegation.agyInputTokens + delegation.agyOutputTokens
        let guardFraction = limits.maxAgyTokens > 0 ? Double(used) / Double(limits.maxAgyTokens) : 0
        lines.append("  cota gemini  \(bar(guardFraction, width: 20)) \(number(used))/\(number(limits.maxAgyTokens))")
        if !callers.isEmpty {
            let breakdown = Caller.allCases
                .compactMap { caller -> String? in
                    guard let count = callers[caller] else { return nil }
                    return "\(caller.label) \(count)"
                }
                .joined(separator: " · ")
            lines.append("  origem       \(breakdown)")
        }
        return lines.joined(separator: "\n")
    }

    static func pad(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - text.count)) + text
    }

    static func percentLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value > 0, value < 0.1 { return "<0,1% da janela" }
        return String(format: "%.1f%% da janela", value).replacingOccurrences(of: ".", with: ",")
    }

    public static func render(_ report: SavingsReport, width: Int = 64) -> String {
        let window = report.window
        let delegation = report.delegation
        var lines: [String] = []

        func rule(_ title: String) {
            lines.append("")
            lines.append(title.uppercased())
            lines.append(String(repeating: "─", count: min(width, 64)))
        }

        func row(_ label: String, _ value: String, note: String = "") {
            let padded = label.padding(toLength: 30, withPad: " ", startingAt: 0)
            let aligned = String(repeating: " ", count: max(0, 13 - value.count)) + value
            lines.append("  \(padded)\(aligned)\(note.isEmpty ? "" : "  \(note)")")
        }

        // MARK: Janela

        let localStart = window.firstTurn ?? window.start
        let elapsed = Date().timeIntervalSince(localStart)
        rule("janela de \(report.windowLength.components.seconds / 3600) horas")
        lines.append("  USO LOCAL 5H: início \(time(localStart)) · decorrido \(clock(elapsed)) · restam \(clock(Double(report.remaining.components.seconds)))")
        if let snapshot = window.rateLimits?.primary, let used = report.fiveHourUsedPercent, let remaining = report.fiveHourRemainingPercent {
            let reset = snapshot.resetsAt.map { " · reset \(time($0))" } ?? ""
            lines.append("  limite Codex 5h: \(decimal(used))% usado · \(decimal(remaining))% restante\(reset)")
        } else {
            lines.append("  limite Codex 5h: indisponível no transcript local")
        }
        lines.append("")
        for source in UsageWindow.Source.allCases {
            let consumption = window.bySource[source] ?? UsageWindow.Consumption()
            row(source.rawValue, number(consumption.billable), note: "\(consumption.turns) turnos")
        }
        row("total processado", number(window.total.billable))
        lines.append("  (leitura de cache, mais barata, à parte: \(number(window.total.cachedInputTokens)))")

        // MARK: Custo da delegação

        rule("o que a delegação custou a você")
        row("chamadas", number(delegation.calls), note: "\(delegation.cacheHits) servidas do cache")
        row("tokens externos", number(delegation.externalTokens), note: "medida do executor")
        row("caracteres recebidos", number(delegation.responseCharacters), note: "medida exata")
        row("≈ tokens no seu contexto", number(delegation.estimatedLocalCost), note: percent(report.percentOfWindow(delegation.estimatedLocalCost)))
        lines.append("  Conversão a \(SavingsReport.charactersPerToken) caracteres por token — estimativa.")

        // MARK: Trabalho deslocado

        rule("o que rodou no gemini em vez de aqui")
        let savingsPercent = report.estimatedSavingsPercent(delegation.displacedTokens)
        row("tokens processados lá", number(delegation.displacedTokens), note: savingsPercent.map { "\(decimal($0))% da cota de 5h (estimativa)" } ?? "percentual estimado indisponível")
        if delegation.calls > 0 {
            row("por chamada", number(delegation.displacedTokens / delegation.calls))
            row("alavancagem", String(format: "%.0f×", delegation.leverage), note: "por token gasto aqui")
        }
        lines.append("")
        lines.append(wrap("""
        Isto é um LIMITE SUPERIOR da economia, não a economia. Mede o trabalho \
        que aconteceu do outro lado; parte dele talvez nunca fosse feita aqui. \
        O overhead fixo do agy (\(number(SavingsReport.agyBaselineInputTokens)) tokens por chamada) já foi descontado.
        """, width: width, indent: "  "))

        // MARK: Cache

        rule("o que o cache dispensou")
        row("respostas reaproveitadas", number(delegation.cacheHits))
        row("≈ tokens poupados aqui", number(delegation.estimatedCacheSaving), note: percent(report.percentOfWindow(delegation.estimatedCacheSaving)))
        lines.append("")
        lines.append(wrap("""
        O cache evita chamadas ao agy e espera; a resposta reaproveitada ainda \
        entra no seu contexto como qualquer outra. A economia acima é a de \
        repetições exatas, não a da delegação em si.
        """, width: width, indent: "  "))

        if !window.unreadableFiles.isEmpty {
            rule("avisos")
            lines.append("  \(window.unreadableFiles.count) transcrito(s) ilegível(is); os números são um piso.")
        }

        lines.append("")
        lines.append("  Gasto e restante da conta vêm do snapshot local do limite de 5h.")
        lines.append("  Economia percentual é extrapolação estimada; os demais percentuais")
        lines.append("  usam o consumo observado.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatação

    static func number(_ value: Int) -> String {
        let digits = String(value)
        var result = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { result.append(" ") }
            result.append(character)
        }
        return String(result.reversed())
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "" }
        if value > 0, value < 0.1 { return "<0,1% da janela" }
        return String(format: "%.1f%% da janela", value).replacingOccurrences(of: ".", with: ",")
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return "\(total / 3600)h\(String(format: "%02d", (total % 3600) / 60))"
    }

    public static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func wrap(_ text: String, width: Int, indent: String) -> String {
        var lines: [String] = []
        var current = indent
        for word in text.split(whereSeparator: \.isWhitespace) {
            if current.count + word.count + 1 > width, current != indent {
                lines.append(current)
                current = indent
            }
            current += (current == indent ? "" : " ") + word
        }
        if current != indent { lines.append(current) }
        return lines.joined(separator: "\n")
    }
}
