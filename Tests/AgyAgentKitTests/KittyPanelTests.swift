import Testing
import Foundation
@testable import AgyAgentKit

/// Runner falso que devolve resultados em sequência, na ordem das chamadas —
/// necessário aqui porque `ensureOpen` faz duas chamadas ao mesmo executável
/// (`kitty @ ls`, depois talvez `kitty @ launch`).
final class QueuedProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ProcessResult]
    private var _plans: [ProcessPlan] = []

    init(_ results: [ProcessResult]) {
        self.queue = results
    }

    var plans: [ProcessPlan] {
        lock.lock()
        defer { lock.unlock() }
        return _plans
    }

    func run(_ plan: ProcessPlan) throws -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }
        _plans.append(plan)
        guard !queue.isEmpty else {
            return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        return queue.removeFirst()
    }
}

@Suite("Busca de aba no JSON do kitty")
struct KittyLsParsingTests {
    /// Amostra real de `kitty @ ls` (0.47.4), reduzida aos campos usados.
    static let sample = #"""
    [
     {
      "id": 1,
      "tabs": [
       {"id": 1, "title": "developer@example-host:~/Projects"},
       {"id": 6, "title": "agy-agent"}
      ]
     },
     {
      "id": 2,
      "tabs": [
       {"id": 9, "title": "outro trabalho"}
      ]
     }
    ]
    """#

    @Test("Encontra o título em qualquer janela do SO, não só a primeira")
    func findsAcrossWindows() {
        #expect(KittyPanel.containsTab(titled: "agy-agent", inLsOutput: Self.sample))
        #expect(!KittyPanel.containsTab(titled: "não existe", inLsOutput: Self.sample))
    }

    @Test("JSON inválido não derruba a checagem, só devolve não encontrado")
    func toleratesGarbage() {
        #expect(!KittyPanel.containsTab(titled: "agy-agent", inLsOutput: "não é json"))
        #expect(!KittyPanel.containsTab(titled: "agy-agent", inLsOutput: ""))
    }

    @Test("Correspondência é exata, não substring")
    func exactMatchOnly() {
        // Um título de janela comum que contivesse "agy-agent" como
        // substring não pode gerar falso positivo.
        let output = #"[{"id":1,"tabs":[{"id":1,"title":"vendo agy-agent-old no editor"}]}]"#
        #expect(!KittyPanel.containsTab(titled: "agy-agent", inLsOutput: output))
    }
}

@Suite("Abertura do painel")
struct KittyPanelTests {
    let workingDirectory = URL(filePath: "/tmp", directoryHint: .isDirectory)
    /// Aponta sempre para um "kitty" que existe, sem tocar no disco real —
    /// mesmo padrão de injeção usado em `AgyLocatorTests`.
    let kittyExists: @Sendable (URL) -> Bool = { $0.lastPathComponent == "kitty" }

    @Test("Fora do kitty, não tenta nada")
    func unavailableOutsideKitty() {
        let fake = QueuedProcessRunner([])
        let result = KittyPanel(processRunner: fake, isExecutable: kittyExists).ensureOpen(
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: workingDirectory,
            panelCommand: ["agy-agent", "watch"]
        )
        #expect(result == .unavailable("fora de uma janela kitty (KITTY_LISTEN_ON ausente)"))
        #expect(fake.plans.isEmpty)
    }

    @Test("Sem o binário kitty no PATH, também não tenta")
    func unavailableWithoutBinary() {
        let fake = QueuedProcessRunner([])
        let result = KittyPanel(processRunner: fake, isExecutable: { _ in false }).ensureOpen(
            environment: ["KITTY_LISTEN_ON": "unix:/x", "PATH": "/usr/bin:/bin"],
            workingDirectory: workingDirectory,
            panelCommand: ["agy-agent", "watch"]
        )
        #expect(result == .unavailable("binário kitty não encontrado no PATH"))
        #expect(fake.plans.isEmpty)
    }

    @Test("Aba ausente: consulta e depois lança")
    func opensWhenAbsent() throws {
        let fake = QueuedProcessRunner([
            ProcessResult(exitCode: 0, standardOutput: #"[{"id":1,"tabs":[]}]"#, standardError: ""),
            ProcessResult(exitCode: 0, standardOutput: "9\n", standardError: ""),
        ])
        let environment = ["KITTY_LISTEN_ON": "unix:/x", "PATH": "/usr/bin:/bin"]
        let result = KittyPanel(processRunner: fake, isExecutable: kittyExists).ensureOpen(
            environment: environment,
            workingDirectory: workingDirectory,
            panelCommand: ["/x/agy-agent", "watch", "15"]
        )
        #expect(result == .opened)
        #expect(fake.plans.count == 2)
        let launchPlan = try #require(fake.plans.last)
        #expect(launchPlan.arguments.contains("--tab-title=agy-agent"))
        #expect(launchPlan.arguments.contains("--keep-focus"))
        #expect(launchPlan.arguments.contains("--location=after"))
        #expect(launchPlan.arguments.suffix(3) == ["/x/agy-agent", "watch", "15"])
    }

    @Test("Aba já aberta: não lança de novo")
    func doesNotDuplicate() throws {
        let fake = QueuedProcessRunner([
            ProcessResult(exitCode: 0, standardOutput: #"[{"id":1,"tabs":[{"id":1,"title":"agy-agent"}]}]"#, standardError: ""),
        ])
        let result = KittyPanel(processRunner: fake, isExecutable: kittyExists).ensureOpen(
            environment: ["KITTY_LISTEN_ON": "unix:/x", "PATH": "/usr/bin:/bin"],
            workingDirectory: workingDirectory,
            panelCommand: ["agy-agent", "watch"]
        )
        #expect(result == .alreadyOpen)
        // Só a consulta (`@ ls`) rodou; nenhum `@ launch`.
        #expect(fake.plans.count == 1)
    }

    @Test("kitty @ ls indisponível: tenta lançar mesmo assim")
    func attemptsLaunchWhenLsFails() throws {
        // Não saber se a aba existe é mais seguro resolver tentando abrir do
        // que desistir silenciosamente — o pior caso é uma aba duplicada.
        let fake = QueuedProcessRunner([
            ProcessResult(exitCode: 1, standardOutput: "", standardError: "erro"),
            ProcessResult(exitCode: 0, standardOutput: "9\n", standardError: ""),
        ])
        let result = KittyPanel(processRunner: fake, isExecutable: kittyExists).ensureOpen(
            environment: ["KITTY_LISTEN_ON": "unix:/x", "PATH": "/usr/bin:/bin"],
            workingDirectory: workingDirectory,
            panelCommand: ["agy-agent", "watch"]
        )
        #expect(result == .opened)
        #expect(fake.plans.count == 2)
    }

    @Test("Falha do lançamento é reportada, não escondida")
    func reportsLaunchFailure() throws {
        let fake = QueuedProcessRunner([
            ProcessResult(exitCode: 0, standardOutput: #"[{"id":1,"tabs":[]}]"#, standardError: ""),
            ProcessResult(exitCode: 1, standardOutput: "", standardError: "no such window"),
        ])
        let result = KittyPanel(processRunner: fake, isExecutable: kittyExists).ensureOpen(
            environment: ["KITTY_LISTEN_ON": "unix:/x", "PATH": "/usr/bin:/bin"],
            workingDirectory: workingDirectory,
            panelCommand: ["agy-agent", "watch"]
        )
        guard case .failed(let reason) = result else {
            Issue.record("esperado failed, veio \(result)")
            return
        }
        #expect(reason.contains("no such window"))
    }
}
