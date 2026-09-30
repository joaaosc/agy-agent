import Foundation

/// Renderização curta e estável do comando `usage`.
///
/// Os três números têm fontes diferentes: o primeiro é uma estimativa baseada
/// no transcript local, o segundo é o snapshot oficial presente no transcript,
/// e o terceiro é o contador local do executor externo.
public enum UsageRenderer {
    public static let barWidth = 12

    public static func render(
        window: UsageWindow.Result,
        externalTokens: Int,
        maxExternalTokens: Int,
        now: Date = Date()
    ) -> String {
        let claude: String
        if let claudeStart = window.firstTurnBySource[.claudeCode] {
            let claudeRemaining = max(0, claudeStart.addingTimeInterval(5 * 3600).timeIntervalSince(now))
            let claudeProgress = min(1, max(0, 1 - claudeRemaining / (5 * 3600)))
            let claudeReset = time(claudeStart.addingTimeInterval(5 * 3600))
            claude = "Claude 5h \(bar(claudeProgress)) restante \(clock(claudeRemaining)) · reset \(claudeReset) (estimativa local; percentual oficial indisponível)"
        } else {
            claude = "Claude 5h \(bar(0)) restante 5h00 · sem uso na janela local (percentual oficial indisponível)"
        }

        let codex: String
        if let primary = window.rateLimits?.primary,
           primary.windowMinutes == 300,
           primary.isCurrent(at: now) {
            let remaining = min(100, max(0, 100 - primary.usedPercent))
            let reset = primary.resetsAt.map(time) ?? "desconhecido"
            codex = "Codex 5h \(bar(1 - remaining / 100)) usado \(decimal(100 - remaining))% · restante \(decimal(remaining))% · reset \(reset) (oficial)"
        } else {
            codex = "Codex 5h \(bar(0, unknown: true)) restante indisponível (rate_limits local ausente ou expirado)"
        }

        let boundedMax = max(0, maxExternalTokens)
        let boundedUsed = max(0, externalTokens)
        let fraction = boundedMax > 0 ? Double(boundedUsed) / Double(boundedMax) : 0
        let gemini = "Gemini 5h \(bar(fraction)) \(number(boundedUsed))/\(number(boundedMax)) tokens externos · \(decimal(fraction * 100))% de maxAgyTokens"
        return [claude, codex, gemini].joined(separator: "\n")
    }

    private static func bar(_ fraction: Double, unknown: Bool = false) -> String {
        if unknown { return "[????????????]" }
        let filled = Int((min(1, max(0, fraction)) * Double(barWidth)).rounded())
        return "[" + String(repeating: "█", count: filled)
            + String(repeating: "·", count: barWidth - filled) + "]"
    }

    private static func number(_ value: Int) -> String {
        let digits = String(value)
        var result = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { result.append(" ") }
            result.append(character)
        }
        return String(result.reversed())
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let minutes = String(format: "%02d", (total % 3600) / 60)
        return "\(total / 3600)h\(minutes)"
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// Roteamento puro usado para que o alias `usage` não dependa do diretório
/// corrente nem de heurísticas sobre o primeiro argumento.
public enum CommandRouting {
    public static func arguments(for commandLine: [String]) -> [String] {
        guard let executable = commandLine.first else { return [] }
        let name = URL(filePath: executable, directoryHint: .notDirectory).lastPathComponent
        guard name == "usage" else { return Array(commandLine.dropFirst()) }
        return ["usage"] + commandLine.dropFirst()
    }
}
