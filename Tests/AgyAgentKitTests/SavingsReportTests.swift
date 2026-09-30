import Testing
import Foundation
@testable import AgyAgentKit

@Suite("Leitura de consumo dos agentes")
struct UsageWindowTests {
    @Test("Linha do Claude Code separa entrada nova de leitura de cache")
    func parsesClaudeLine() throws {
        let line = #"""
        {"timestamp":"2026-09-19T21:26:47.399Z","message":{"model":"claude-opus-5","usage":{"input_tokens":2,"cache_creation_input_tokens":25672,"cache_read_input_tokens":32512,"output_tokens":155}}}
        """#
        let (date, consumption) = try #require(UsageWindow.parseClaudeLine(Data(line.utf8)))
        #expect(consumption.freshInputTokens == 25674)
        #expect(consumption.cachedInputTokens == 32512)
        #expect(consumption.outputTokens == 155)
        #expect(consumption.billable == 25829)
        #expect(consumption.turns == 1)
        #expect(abs(date.timeIntervalSince1970 - 1789853207.399) < 1)
    }

    @Test("Linha do Codex desconta a parte cacheada da entrada")
    func parsesCodexLine() throws {
        // `input_tokens` do Codex já inclui `cached_input_tokens`.
        let line = #"""
        {"timestamp":"2026-09-18T08:35:12.741Z","type":"token_usage_record","payload":{"usage":{"input_tokens":33964,"cached_input_tokens":4000,"cache_write_input_tokens":100,"output_tokens":273}}}
        """#
        let (_, consumption) = try #require(UsageWindow.parseCodexLine(Data(line.utf8)))
        #expect(consumption.freshInputTokens == 30064)
        #expect(consumption.cachedInputTokens == 4000)
        #expect(consumption.outputTokens == 273)
    }

    @Test("Seleciona o snapshot de limite de 5h mais recente")
    func parsesLatestCodexRateLimitSnapshot() throws {
        let line = #"{"timestamp":"2026-09-29T12:00:02Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":42.5,"window_minutes":300,"resets_at":1790335749},"secondary":{"used_percent":8,"window_minutes":10080,"resets_at":1790762608}}}}"#
        let snapshot = try #require(UsageWindow.parseCodexRateLimitsLine(Data(line.utf8)))
        #expect(snapshot.primary?.usedPercent == 42.5)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.secondary?.windowMinutes == 10080)
        #expect(snapshot.primary?.resetsAt != nil)
    }

    @Test("A varredura ignora symlink")
    func transcriptHardening() throws {
        let directory = try TemporaryDirectory()
        let real = directory.url.appending(path: "real.jsonl")
        let link = directory.url.appending(path: "link.jsonl")
        try Data("{\"type\":\"world_state\"}\n".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(UsageWindow.transcripts(under: directory.url, modifiedAfter: .distantPast).map(\.lastPathComponent) == ["real.jsonl"])
    }

    @Test("Linha JSONL excessiva é descartada sem carregar o arquivo inteiro")
    func oversizedLineIsSkipped() throws {
        let directory = try TemporaryDirectory()
        let root = directory.url.appending(path: ".codex/sessions/2026/09/29")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "large.jsonl")
        let valid = #"{"timestamp":"2026-09-29T12:00:00Z","type":"token_usage_record","payload":{"usage":{"input_tokens":1,"output_tokens":1}}}"#
        try Data((String(repeating: "x", count: 1_100_000) + valid + "\n" + valid).utf8).write(to: file)
        let result = UsageWindow(homeDirectory: directory.url).consumption(
            from: UsageWindow.date(from: "2026-09-29T11:00:00Z")!,
            to: UsageWindow.date(from: "2026-09-29T13:00:00Z")!
        )
        #expect(result.total.outputTokens == 1)
    }

    @Test("A soma Codex respeita a borda da janela ativa do snapshot")
    func codexConsumptionUsesActiveRateWindow() throws {
        let directory = try TemporaryDirectory()
        let root = directory.url.appending(path: ".codex/sessions/2026/09/29")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "window.jsonl")
        func usage(_ timestamp: String, _ input: Int) -> String {
            "{\"timestamp\":\"\(timestamp)\",\"type\":\"token_usage_record\",\"payload\":{\"usage\":{\"input_tokens\":\(input),\"output_tokens\":0}}}"
        }
        let snapshot = "{\"timestamp\":\"2026-09-29T12:02:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":20,\"window_minutes\":300,\"resets_at\":1790701200}}}}"
        try Data([
            usage("2026-09-29T11:59:59Z", 100),
            usage("2026-09-29T12:00:00Z", 10),
            usage("2026-09-29T12:01:00Z", 20),
            snapshot,
        ].joined(separator: "\n").utf8).write(to: file)

        let result = UsageWindow(homeDirectory: directory.url).consumption(
            from: UsageWindow.date(from: "2026-09-29T10:00:00Z")!,
            to: UsageWindow.date(from: "2026-09-29T13:00:00Z")!
        )
        #expect(result.bySource[.codex]?.billable == 30)
        #expect(result.activeRateLimitWindowStart == UsageWindow.date(from: "2026-09-29T12:00:00Z"))
    }

    @Test("Linhas irrelevantes são ignoradas sem erro")
    func ignoresOtherLines() {
        #expect(UsageWindow.parseClaudeLine(Data(#"{"type":"user"}"#.utf8)) == nil)
        #expect(UsageWindow.parseCodexLine(Data(#"{"type":"world_state","payload":{}}"#.utf8)) == nil)
        #expect(UsageWindow.parseClaudeLine(Data("não é json".utf8)) == nil)
    }

    @Test("Timestamp sem fração também é aceito")
    func toleratesTimestampWithoutFraction() {
        #expect(UsageWindow.date(from: "2026-09-19T21:26:47Z") != nil)
        #expect(UsageWindow.date(from: "2026-09-19T21:26:47.399Z") != nil)
        #expect(UsageWindow.date(from: nil) == nil)
        #expect(UsageWindow.date(from: "ontem") == nil)
    }

    @Test("Só transcritos modificados dentro da janela são abertos")
    func filtersByModificationDate() throws {
        let directory = try TemporaryDirectory()
        let recent = directory.url.appending(path: "recente.jsonl")
        let old = directory.url.appending(path: "antigo.jsonl")
        try Data("{}".utf8).write(to: recent)
        try Data("{}".utf8).write(to: old)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
            ofItemAtPath: old.path(percentEncoded: false)
        )
        // Um arquivo que não é tocado desde ontem não pode conter turno de hoje.
        let found = UsageWindow.transcripts(under: directory.url, modifiedAfter: Date().addingTimeInterval(-3600))
        #expect(found.map(\.lastPathComponent) == ["recente.jsonl"])
    }

    @Test("Diretório inexistente devolve lista vazia, não erro")
    func missingDirectory() {
        let result = UsageWindow(homeDirectory: URL(filePath: "/nao/existe", directoryHint: .isDirectory))
            .consumption(from: Date().addingTimeInterval(-3600))
        #expect(result.total.total == 0)
        #expect(result.unreadableFiles.isEmpty)
    }
}

@Suite("Contabilidade de economia")
struct SavingsReportTests {
    func delegation(
        calls: Int = 1,
        hits: Int = 0,
        characters: Int = 4000,
        cachedCharacters: Int = 0,
        input: Int = 100_000,
        output: Int = 2000
    ) -> SavingsReport.Delegation {
        SavingsReport.Delegation(
            calls: calls,
            cacheHits: hits,
            responseCharacters: characters,
            charactersFromCache: cachedCharacters,
            agyInputTokens: input,
            agyOutputTokens: output
        )
    }

    @Test("O overhead fixo do agy é descontado do trabalho deslocado")
    func baselineIsSubtracted() {
        let single = delegation(calls: 1, input: 100_000, output: 2000)
        #expect(single.displacedTokens == 100_000 - 24_800 + 2000)

        // Duas chamadas pagam o overhead duas vezes.
        let double = delegation(calls: 2, input: 100_000, output: 2000)
        #expect(double.displacedTokens == 100_000 - 49_600 + 2000)
    }

    @Test("Entrada abaixo do overhead não vira deslocamento negativo")
    func neverNegative() {
        #expect(delegation(calls: 1, input: 10_000, output: 0).displacedTokens == 0)
    }

    @Test("A alavancagem é trabalho lá por token gasto aqui")
    func leverage() {
        // 4000 caracteres ≈ 1000 tokens locais; 77 200 deslocados.
        let summary = delegation(characters: 4000, input: 100_000, output: 2000)
        #expect(summary.estimatedLocalCost == 1000)
        #expect(abs(summary.leverage - 77.2) < 0.1)
    }

    @Test("Sem resposta recebida, a alavancagem é zero e não infinito")
    func leverageWithoutLocalCost() {
        #expect(delegation(characters: 0).leverage == 0)
    }

    @Test("A economia do cache vem dos caracteres reaproveitados")
    func cacheSaving() {
        #expect(delegation(cachedCharacters: 800).estimatedCacheSaving == 200)
    }

    @Test("Percentual usa o consumo observado como base")
    func percentOfWindow() {
        let window = UsageWindow.Result(
            start: Date().addingTimeInterval(-3600),
            end: Date(),
            bySource: [.claudeCode: UsageWindow.Consumption(freshInputTokens: 90_000, outputTokens: 10_000, turns: 10)],
            unreadableFiles: [],
            firstTurn: Date().addingTimeInterval(-3600)
        )
        let report = SavingsReport(window: window, delegation: delegation(), windowLength: .seconds(18_000))
        #expect(report.percentOfWindow(10_000) == 10)
    }

    @Test("Janela sem consumo não produz percentual inventado")
    func percentWithoutBase() {
        let window = UsageWindow.Result(start: Date(), end: Date(), bySource: [:], unreadableFiles: [], firstTurn: nil)
        let report = SavingsReport(window: window, delegation: delegation(), windowLength: .seconds(18_000))
        #expect(report.percentOfWindow(1000) == nil)
    }

    @Test("Percentual de economia usa o snapshot de 5h e cai honestamente sem ele")
    func estimatedSavingsPercent() {
        let snapshot = UsageWindow.RateLimits(
            primary: UsageWindow.RateLimitSnapshot(
                usedPercent: 20, windowMinutes: 300, resetsAt: nil, timestamp: Date()
            ), secondary: nil, timestamp: Date()
        )
        let window = UsageWindow.Result(
            start: Date(), end: Date(),
            bySource: [
                .codex: UsageWindow.Consumption(freshInputTokens: 80, outputTokens: 20),
                .claudeCode: UsageWindow.Consumption(freshInputTokens: 9_000, outputTokens: 1_000),
            ],
            unreadableFiles: [], firstTurn: nil, rateLimits: snapshot
        )
        let report = SavingsReport(window: window, delegation: delegation(), windowLength: .seconds(18_000))
        #expect(report.fiveHourUsedPercent == 20)
        #expect(report.fiveHourRemainingPercent == 80)
        #expect(report.estimatedSavingsPercent(10) == 2)

        let stale = UsageWindow.RateLimits(
            primary: UsageWindow.RateLimitSnapshot(
                usedPercent: 20, windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(-1), timestamp: Date().addingTimeInterval(-3600)
            ), secondary: nil, timestamp: Date().addingTimeInterval(-3600)
        )
        let staleReport = SavingsReport(
            window: UsageWindow.Result(start: Date(), end: Date(), bySource: window.bySource, unreadableFiles: [], firstTurn: nil, rateLimits: stale),
            delegation: delegation(), windowLength: .seconds(18_000)
        )
        #expect(staleReport.fiveHourUsedPercent == nil)

        let fallback = SavingsReport(
            window: UsageWindow.Result(start: Date(), end: Date(), bySource: window.bySource, unreadableFiles: [], firstTurn: nil),
            delegation: delegation(), windowLength: .seconds(18_000)
        )
        #expect(fallback.estimatedSavingsPercent(10) == nil)
    }

    @Test("O tempo restante conta do primeiro turno e nunca fica negativo")
    func remainingIsAnchoredAndClamped() {
        // Primeiro turno há 10 horas, janela de 5: já expirou.
        let expired = UsageWindow.Result(
            start: Date().addingTimeInterval(-18_000),
            end: Date(),
            bySource: [:],
            unreadableFiles: [],
            firstTurn: Date().addingTimeInterval(-36_000)
        )
        #expect(SavingsReport(window: expired, delegation: delegation(), windowLength: .seconds(18_000)).remaining == .seconds(0))

        // Primeiro turno há 1 hora: restam cerca de 4.
        let running = UsageWindow.Result(
            start: Date().addingTimeInterval(-18_000),
            end: Date(),
            bySource: [:],
            unreadableFiles: [],
            firstTurn: Date().addingTimeInterval(-3600)
        )
        let report = SavingsReport(window: running, delegation: delegation(), windowLength: .seconds(18_000))
        #expect(abs(report.remaining.components.seconds - 14_400) < 5)
        #expect(abs(report.elapsedFraction - 0.2) < 0.01)
    }

    @Test("Sem nenhum turno, a janela inteira está livre")
    func remainingWithoutTurns() {
        let empty = UsageWindow.Result(start: Date(), end: Date(), bySource: [:], unreadableFiles: [], firstTurn: nil)
        let report = SavingsReport(window: empty, delegation: delegation(), windowLength: .seconds(18_000))
        #expect(report.remaining == .seconds(18_000))
        #expect(report.elapsedFraction == 0)
    }
}

@Suite("Desenho do relatório")
struct SavingsRendererTests {
    @Test("Números grandes são agrupados por milhar")
    func groupsThousands() {
        #expect(SavingsRenderer.number(1) == "1")
        #expect(SavingsRenderer.number(1000) == "1 000")
        #expect(SavingsRenderer.number(279_064) == "279 064")
    }

    @Test("Percentual muito pequeno não é arredondado para zero")
    func tinyPercent() {
        // Mostrar "0,0%" faria parecer que a delegação não custou nada.
        #expect(SavingsRenderer.percent(0.04) == "<0,1% da janela")
        #expect(SavingsRenderer.percent(11.83) == "11,8% da janela")
        #expect(SavingsRenderer.percent(nil) == "")
    }

    @Test("O relatório rotula estimativa, limite superior e medida exata")
    func labelsHonestly() {
        let window = UsageWindow.Result(
            start: Date().addingTimeInterval(-3600),
            end: Date(),
            bySource: [.claudeCode: UsageWindow.Consumption(freshInputTokens: 100_000, outputTokens: 5000, turns: 20)],
            unreadableFiles: [],
            firstTurn: Date().addingTimeInterval(-1800)
        )
        let report = SavingsReport(
            window: window,
            delegation: SavingsReport.Delegation(
                calls: 3, cacheHits: 1, responseCharacters: 9000,
                charactersFromCache: 1000, agyInputTokens: 200_000, agyOutputTokens: 6000
            ),
            windowLength: .seconds(18_000)
        )
        let text = SavingsRenderer.render(report)
        #expect(text.contains("medida exata"))
        #expect(text.contains("estimativa"))
        #expect(text.contains("LIMITE SUPERIOR"))
        #expect(text.contains("snapshot local do limite de 5h"))
        #expect(text.contains("alavancagem"))
    }

    @Test("Transcritos ilegíveis são reportados, não escondidos")
    func reportsUnreadableFiles() {
        let window = UsageWindow.Result(
            start: Date(), end: Date(),
            bySource: [.claudeCode: UsageWindow.Consumption(freshInputTokens: 10, turns: 1)],
            unreadableFiles: ["/x.jsonl"],
            firstTurn: Date()
        )
        let report = SavingsReport(window: window, delegation: SavingsReport.Delegation(), windowLength: .seconds(18_000))
        #expect(SavingsRenderer.render(report).contains("ilegível"))
    }
}

@Suite("Instalação")
struct InstallerTests {
    func makeInstaller(_ directory: borrowing TemporaryDirectory) -> Installer {
        Installer(
            paths: Paths.resolve(environment: ["AGY_AGENT_HOME": directory.url.path(percentEncoded: false)], homeDirectory: directory.url),
            homeDirectory: directory.url
        )
    }

    func fakeExecutable(_ directory: borrowing TemporaryDirectory, named name: String = "agy-agent") throws -> URL {
        let url = directory.url.appending(path: name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    @Test("Instala como symlink, não cópia")
    func createsSymlink() throws {
        let directory = try TemporaryDirectory()
        let installer = makeInstaller(directory)
        let report = try installer.install(executable: try fakeExecutable(directory), environment: [:])

        #expect(report.created)
        // Cópia ficaria desatualizada em silêncio depois de cada build.
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: report.linkPath)
        #expect(destination == report.target)
    }

    @Test("Instalar duas vezes é idempotente")
    func idempotent() throws {
        let directory = try TemporaryDirectory()
        let installer = makeInstaller(directory)
        let executable = try fakeExecutable(directory)
        _ = try installer.install(executable: executable, environment: [:])
        let second = try installer.install(executable: executable, environment: [:])

        #expect(!second.created)
        #expect(!second.replaced)
        #expect(second.seededPrompts.isEmpty)
        #expect(!second.wroteConfigTemplate)
    }

    @Test("Link apontando para outro alvo é substituído")
    func replacesStaleLink() throws {
        let directory = try TemporaryDirectory()
        let installer = makeInstaller(directory)
        _ = try installer.install(executable: try fakeExecutable(directory, named: "antigo"), environment: [:])
        let second = try installer.install(executable: try fakeExecutable(directory, named: "novo"), environment: [:])

        #expect(second.replaced)
        #expect(second.target.hasSuffix("novo"))
    }

    @Test("Arquivo comum no caminho do link não é apagado")
    func refusesToOverwriteRegularFile() throws {
        let directory = try TemporaryDirectory()
        let installer = makeInstaller(directory)
        try FileManager.default.createDirectory(at: installer.linkDirectory, withIntermediateDirectories: true)
        try Data("algo do usuário".utf8).write(to: installer.linkURL)

        #expect(throws: AgyAgentError.self) {
            try installer.install(executable: try fakeExecutable(directory), environment: [:])
        }
        #expect(try String(contentsOf: installer.linkURL, encoding: .utf8) == "algo do usuário")
    }

    @Test("Executável inexistente é recusado antes de mexer em qualquer coisa")
    func rejectsMissingExecutable() throws {
        let directory = try TemporaryDirectory()
        let installer = makeInstaller(directory)
        #expect(throws: AgyAgentError.self) {
            try installer.install(
                executable: URL(filePath: "/nao/existe/agy-agent", directoryHint: .notDirectory),
                environment: [:]
            )
        }
        #expect(!FileManager.default.fileExists(atPath: installer.linkURL.path(percentEncoded: false)))
    }

    @Test("A instalação semeia prompts e modelo de configuração")
    func seedsConfiguration() throws {
        let directory = try TemporaryDirectory()
        let installer = makeInstaller(directory)
        let report = try installer.install(executable: try fakeExecutable(directory), environment: [:])

        #expect(Set(report.seededPrompts) == Set(Mode.allCases))
        #expect(report.wroteConfigTemplate)

        // O modelo é todo comentado: descomentar é ato deliberado.
        let paths = Paths.resolve(environment: ["AGY_AGENT_HOME": directory.url.path(percentEncoded: false)], homeDirectory: directory.url)
        let template = try String(contentsOf: paths.configFile, encoding: .utf8)
        let parsed = try Configuration.parse(template)
        for mode in Mode.allCases {
            #expect(parsed.settings(for: mode) == ModeSettings.defaults(for: mode))
        }
    }

    @Test("Detecta se ~/.local/bin está no PATH")
    func detectsPath() throws {
        let directory = try TemporaryDirectory()
        let installer = makeInstaller(directory)
        let executable = try fakeExecutable(directory)

        #expect(!(try installer.install(executable: executable, environment: ["PATH": "/usr/bin"]).pathContainsLinkDirectory))
        let withPath = try installer.install(
            executable: executable,
            environment: ["PATH": "/usr/bin:\(installer.linkDirectory.path(percentEncoded: false))"]
        )
        #expect(withPath.pathContainsLinkDirectory)
    }

    @Test("Desinstalar remove o link e preserva os dados")
    func uninstallKeepsData() throws {
        let directory = try TemporaryDirectory()
        let installer = makeInstaller(directory)
        _ = try installer.install(executable: try fakeExecutable(directory), environment: [:])

        #expect(try installer.uninstall())
        #expect(!FileManager.default.fileExists(atPath: installer.linkURL.path(percentEncoded: false)))

        let paths = Paths.resolve(environment: ["AGY_AGENT_HOME": directory.url.path(percentEncoded: false)], homeDirectory: directory.url)
        #expect(FileManager.default.fileExists(atPath: paths.configFile.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: paths.promptsDirectory.appending(path: "verify.md").path(percentEncoded: false)))
    }

    @Test("Desinstalar sem link instalado não é erro")
    func uninstallWithoutLink() throws {
        let directory = try TemporaryDirectory()
        #expect(try makeInstaller(directory).uninstall() == false)
    }

    @Test("O diretório de log não é mais criado")
    func noLogDirectory() throws {
        let directory = try TemporaryDirectory()
        let paths = Paths.resolve(environment: ["AGY_AGENT_HOME": directory.url.path(percentEncoded: false)], homeDirectory: directory.url)
        try paths.createWritableDirectories()
        // Nada escreve lá; um diretório que cresceria sem ninguém olhar é
        // risco sem contrapartida.
        #expect(!paths.writableDirectories.contains(paths.logDirectory))
        #expect(!FileManager.default.fileExists(atPath: paths.logDirectory.path(percentEncoded: false)))
    }
}
