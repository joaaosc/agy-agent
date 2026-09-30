import Testing
import Foundation
@testable import AgyAgentKit

/// Runner falso: registra o plano recebido e devolve um resultado combinado.
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _plans: [ProcessPlan] = []
    private let outcome: Result<ProcessResult, any Error>

    init(_ outcome: Result<ProcessResult, any Error>) {
        self.outcome = outcome
    }

    convenience init(standardOutput: String, standardError: String = "", exitCode: Int32 = 0) {
        self.init(.success(ProcessResult(
            exitCode: exitCode,
            standardOutput: standardOutput,
            standardError: standardError
        )))
    }

    var plans: [ProcessPlan] {
        lock.lock()
        defer { lock.unlock() }
        return _plans
    }

    func run(_ plan: ProcessPlan) throws -> ProcessResult {
        lock.lock()
        _plans.append(plan)
        lock.unlock()
        return try outcome.get()
    }
}

@Suite("Runner do agy")
struct AgyRunnerTests {
    static let executable = URL(filePath: "/Users/tester/.local/bin/agy", directoryHint: .notDirectory)
    static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    func makeRunner(_ processRunner: any ProcessRunning) -> AgyRunner {
        AgyRunner(
            executable: Self.executable,
            agyVersion: "1.2.7",
            processRunner: processRunner,
            parentEnvironment: ["HOME": "/Users/tester"],
            clock: { Self.fixedDate }
        )
    }

    @Test("Resposta bem-sucedida vira pacote de evidência com proveniência")
    func successProducesPacket() throws {
        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)
        let packet = try makeRunner(fake).run(AgyInvocationTests.request()).packet

        #expect(packet.response == "OK")
        #expect(packet.agyVersion == "1.2.7")
        #expect(packet.createdAt == Self.fixedDate)
        #expect(packet.conversationID == "3f7b40f1-89f5-45d6-bb68-c2f9a5570935")
        #expect(packet.usage.totalTokens == 24810)
        #expect(packet.cacheKey == AgyInvocationTests.request().query.cacheKey)
    }

    @Test("O plano executado usa o executável resolvido e o ambiente saneado")
    func planIsWellFormed() throws {
        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)
        _ = try makeRunner(fake).run(AgyInvocationTests.request())

        let plan = try #require(fake.plans.first)
        #expect(plan.executable == Self.executable)
        #expect(plan.environment["NO_COLOR"] == "1")
        #expect(plan.environment["HOME"] == "/Users/tester")
        #expect(!plan.arguments.contains { $0 == "--print" || $0.hasPrefix("--print=") })
        #expect(plan.standardInput?.contains("A API X existe") == true)
    }

    @Test("Status diferente de SUCCESS falha mesmo com saída decodificável")
    func nonSuccessStatusFails() {
        let fake = FakeProcessRunner(standardOutput: #"{"status":"ERROR","response":""}"#, standardError: "quota excedida")
        #expect(throws: AgyAgentError.agyFailed(status: "ERROR", output: "quota excedida")) {
            try makeRunner(fake).run(AgyInvocationTests.request())
        }
    }

    @Test("Status de sucesso sem resposta é erro e preserva o diagnóstico")
    func emptySuccessFails() {
        let fake = FakeProcessRunner(
            standardOutput: #"{"status":"SUCCESS","response":"","usage":{"total_tokens":129264}}"#,
            standardError: "warning: o limite encerrou o turno antes da resposta final"
        )
        #expect(throws: AgyAgentError.emptyResponse("warning: o limite encerrou o turno antes da resposta final")) {
            try makeRunner(fake).run(AgyInvocationTests.request())
        }
    }

    @Test("Resposta composta só por espaços também é recusada")
    func whitespaceSuccessFails() {
        let fake = FakeProcessRunner(standardOutput: #"{"status":"SUCCESS","response":"  \n"}"#)
        #expect(throws: AgyAgentError.emptyResponse("")) {
            try makeRunner(fake).run(AgyInvocationTests.request())
        }
    }

    @Test("Saída ilegível com código diferente de zero reporta o stderr")
    func nonZeroExitReportsStderr() {
        let fake = FakeProcessRunner(
            standardOutput: "",
            standardError: "erro: autenticação expirada",
            exitCode: 1
        )
        #expect(throws: AgyAgentError.agyFailed(status: "exit 1", output: "erro: autenticação expirada")) {
            try makeRunner(fake).run(AgyInvocationTests.request())
        }
    }

    @Test("Saída ilegível com código zero é erro de formato")
    func zeroExitWithGarbageIsFormatError() {
        let fake = FakeProcessRunner(standardOutput: "texto sem json", exitCode: 0)
        #expect(throws: AgyAgentError.malformedEnvelope("texto sem json")) {
            try makeRunner(fake).run(AgyInvocationTests.request())
        }
    }

    @Test("Timeout do processo é propagado")
    func timeoutPropagates() {
        let fake = FakeProcessRunner(.failure(AgyAgentError.timedOut(seconds: 195)))
        #expect(throws: AgyAgentError.timedOut(seconds: 195)) {
            try makeRunner(fake).run(AgyInvocationTests.request())
        }
    }

    @Test("Validação acontece antes de lançar o processo")
    func validationBeforeSpawn() {
        let fake = FakeProcessRunner(standardOutput: AgyEnvelopeTests.sample)
        #expect(throws: AgyAgentError.emptyQuestion) {
            try makeRunner(fake).run(AgyInvocationTests.request(question: " "))
        }
        #expect(fake.plans.isEmpty)
    }

    @Test("Leitura de versão usa --version e a primeira linha não vazia")
    func readsVersion() {
        let fake = FakeProcessRunner(standardOutput: "\n1.2.7\nalgo mais\n")
        let version = AgyRunner.readVersion(
            executable: Self.executable,
            processRunner: fake,
            workingDirectory: URL(filePath: "/tmp", directoryHint: .isDirectory),
            environment: [:]
        )
        #expect(version == "1.2.7")
        #expect(fake.plans.first?.arguments == ["--version"])
    }

    @Test("Falha ao ler a versão não interrompe o fluxo")
    func versionFailureIsTolerated() {
        let fake = FakeProcessRunner(.failure(AgyAgentError.agyNotFound("/x")))
        let version = AgyRunner.readVersion(
            executable: Self.executable,
            processRunner: fake,
            workingDirectory: URL(filePath: "/tmp", directoryHint: .isDirectory),
            environment: [:]
        )
        #expect(version == "unknown")
    }
}

@Suite("Execução real de subprocesso")
struct SubprocessRunnerTests {
    func plan(_ arguments: [String], timeout: Duration = .seconds(30)) -> ProcessPlan {
        ProcessPlan(
            executable: URL(filePath: "/bin/sh", directoryHint: .notDirectory),
            arguments: ["-c"] + arguments,
            workingDirectory: URL(filePath: "/tmp", directoryHint: .isDirectory),
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: timeout
        )
    }

    @Test("Captura stdout, stderr e código de saída")
    func capturesStreams() throws {
        let result = try SubprocessRunner().run(plan(["printf saida; printf erro 1>&2; exit 3"]))
        #expect(result.standardOutput == "saida")
        #expect(result.standardError == "erro")
        #expect(result.exitCode == 3)
        #expect(!result.timedOut)
    }

    @Test("Saída maior que o buffer do pipe não trava o processo")
    func largeOutputDoesNotDeadlock() throws {
        // 64 KiB é o tamanho típico do buffer de pipe; sem drenagem
        // concorrente, o filho bloquearia antes de terminar.
        let result = try SubprocessRunner().run(plan(["for i in $(seq 1 20000); do echo linha-de-saida-suficientemente-longa; done"]))
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.count > 200_000)
    }

    @Test("Processo que excede o limite é encerrado e reportado")
    func timeoutTerminates() {
        #expect(throws: AgyAgentError.timedOut(seconds: 1)) {
            try SubprocessRunner().run(plan(["sleep 30"], timeout: .seconds(1)))
        }
    }

    @Test("Executável inexistente produz erro de localização")
    func missingExecutable() {
        let missing = ProcessPlan(
            executable: URL(filePath: "/caminho/inexistente/agy", directoryHint: .notDirectory),
            arguments: [],
            workingDirectory: URL(filePath: "/tmp", directoryHint: .isDirectory),
            environment: [:],
            timeout: .seconds(5)
        )
        #expect(throws: AgyAgentError.agyNotFound("/caminho/inexistente/agy")) {
            try SubprocessRunner().run(missing)
        }
    }

    @Test("O diretório de trabalho é respeitado")
    func honorsWorkingDirectory() throws {
        let result = try SubprocessRunner().run(plan(["pwd"]))
        #expect(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/tmp"))
    }

    @Test("stdin é fechado para que o processo não espere entrada")
    func stdinIsClosed() throws {
        let result = try SubprocessRunner().run(plan(["cat"], timeout: .seconds(10)))
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.isEmpty)
    }
}

/// Runner falso com respostas diferentes por executável, para separar as
/// chamadas ao `git` das chamadas ao `agy`.
final class ScriptedProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _plans: [ProcessPlan] = []
    private var gitOutputs: [String]
    private let agyOutput: String

    init(agyOutput: String, gitOutputs: [String]) {
        self.agyOutput = agyOutput
        self.gitOutputs = gitOutputs
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
        if plan.executable.lastPathComponent == "git" {
            let output = gitOutputs.isEmpty ? "" : gitOutputs.removeFirst()
            return ProcessResult(exitCode: 0, standardOutput: output, standardError: "")
        }
        return ProcessResult(exitCode: 0, standardOutput: agyOutput, standardError: "")
    }
}

@Suite("Detecção de alteração do workspace")
struct WorkspaceGuardTests {
    static let repo = Workspace(root: URL(filePath: "/Users/tester/Repo", directoryHint: .isDirectory), isRepository: true)

    func makeRunner(_ processRunner: any ProcessRunning) -> AgyRunner {
        AgyRunner(
            executable: URL(filePath: "/bin/agy", directoryHint: .notDirectory),
            agyVersion: "1.2.7",
            processRunner: processRunner,
            parentEnvironment: [:],
            clock: { Date(timeIntervalSince1970: 0) },
            guardian: WorkspaceGuard(processRunner: processRunner)
        )
    }

    func inspectRequest() -> DelegationRequest {
        DelegationRequest(
            mode: .inspect,
            question: "por que falha?",
            systemPrompt: "p",
            workspace: Self.repo,
            neutralDirectory: URL(filePath: "/tmp", directoryHint: .isDirectory)
        )
    }

    @Test("Workspace intacto não gera aviso")
    func unchangedWorkspace() throws {
        // status, HEAD (antes) e status, HEAD (depois), todos iguais.
        let fake = ScriptedProcessRunner(
            agyOutput: AgyEnvelopeTests.sample,
            // status (limpo), status+HEAD antes, status+HEAD depois.
            gitOutputs: ["", "", "abc123\n", "", "abc123\n"]
        )
        let outcome = try makeRunner(fake).run(inspectRequest())
        #expect(outcome.warnings.isEmpty)
    }

    @Test("Arquivo alterado durante a chamada gera aviso")
    func changedWorkspace() throws {
        let fake = ScriptedProcessRunner(
            agyOutput: AgyEnvelopeTests.sample,
            gitOutputs: ["", "", "abc123\n", " M Sources/x.swift\n", "abc123\n"]
        )
        let outcome = try makeRunner(fake).run(inspectRequest())
        #expect(outcome.warnings.contains { $0.contains("workspace foi alterado") })
    }

    @Test("Commit criado durante a chamada também é detectado")
    func changedHead() throws {
        let fake = ScriptedProcessRunner(
            agyOutput: AgyEnvelopeTests.sample,
            gitOutputs: ["", "", "abc123\n", "", "def456\n"]
        )
        #expect(try makeRunner(fake).run(inspectRequest()).warnings.contains { $0.contains("workspace foi alterado") })
    }

    @Test("Modo sem workspace não chama o git")
    func noWorkspaceNoGit() throws {
        let fake = ScriptedProcessRunner(agyOutput: AgyEnvelopeTests.sample, gitOutputs: [])
        _ = try makeRunner(fake).run(AgyInvocationTests.request())
        #expect(!fake.plans.contains { $0.executable.lastPathComponent == "git" })
    }

    @Test("Sem Git e sem diretório legível, a verificação é silenciosa, não falsa")
    func unavailableWithoutGitOrDirectory() {
        let failing = FakeProcessRunner(standardOutput: "", standardError: "not a git repository", exitCode: 128)
        let guardian = WorkspaceGuard(processRunner: failing)
        let snapshot = guardian.snapshot(of: Self.repo)
        #expect(!snapshot.isAvailable)
        #expect(guardian.verdict(before: snapshot, after: snapshot) == .unavailable)
        #expect(WorkspaceGuard.Verdict.unavailable.warning == nil)
    }

    @Test("Sem Git, a varredura de arquivos detecta alteração")
    func fileScanFallback() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(path: "a.txt")
        try Data("um".utf8).write(to: file)

        let noGit = FakeProcessRunner(standardOutput: "", standardError: "not a git repository", exitCode: 128)
        let guardian = WorkspaceGuard(processRunner: noGit)
        let workspace = Workspace(root: directory.url, isRepository: false)

        let before = guardian.snapshot(of: workspace)
        #expect(before.source == .fileScan)
        #expect(before.isAvailable)
        #expect(guardian.verdict(before: before, after: guardian.snapshot(of: workspace)) == .unchanged)

        try Data("dois e mais um pouco".utf8).write(to: file)
        #expect(guardian.verdict(before: before, after: guardian.snapshot(of: workspace)) == .changed(.fileScan))
    }

    @Test("Arquivo novo também é detectado pela varredura")
    func fileScanDetectsNewFile() throws {
        let directory = try TemporaryDirectory()
        let noGit = FakeProcessRunner(standardOutput: "", standardError: "no", exitCode: 128)
        let guardian = WorkspaceGuard(processRunner: noGit)
        let workspace = Workspace(root: directory.url, isRepository: false)

        let before = guardian.snapshot(of: workspace)
        try Data("novo".utf8).write(to: directory.url.appending(path: "b.txt"))
        #expect(guardian.verdict(before: before, after: guardian.snapshot(of: workspace)) == .changed(.fileScan))
    }

    @Test("Diretórios derivados são pulados para não gerar alarme falso")
    func skipsDerivedDirectories() throws {
        let directory = try TemporaryDirectory()
        let build = directory.url.appending(path: ".build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)

        let noGit = FakeProcessRunner(standardOutput: "", standardError: "no", exitCode: 128)
        let guardian = WorkspaceGuard(processRunner: noGit)
        let workspace = Workspace(root: directory.url, isRepository: false)

        let before = guardian.snapshot(of: workspace)
        try Data("artefato".utf8).write(to: build.appending(path: "saida.o"))
        #expect(guardian.verdict(before: before, after: guardian.snapshot(of: workspace)) == .unchanged)
    }

    @Test("Varredura não segue symlink para fora do workspace")
    func fileScanDoesNotFollowExternalSymlink() throws {
        let directory = try TemporaryDirectory()
        let outside = directory.url.deletingLastPathComponent().appending(path: "agy-agent-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appending(path: "secret.txt")
        try Data("before".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: directory.url.appending(path: "external"), withDestinationURL: outside)

        let scanner = DefaultWorkspaceFileSystem()
        let before = scanner.fingerprint(of: directory.url, skipping: [], limit: 100)
        try Data("after with a different size".utf8).write(to: secret)
        #expect(scanner.fingerprint(of: directory.url, skipping: [], limit: 100) == before)

        let other = outside.deletingLastPathComponent().appending(path: "agy-agent-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try FileManager.default.removeItem(at: directory.url.appending(path: "external"))
        try FileManager.default.createSymbolicLink(at: directory.url.appending(path: "external"), withDestinationURL: other)
        #expect(scanner.fingerprint(of: directory.url, skipping: [], limit: 100) != before)
    }

    @Test("Fontes diferentes não são comparadas")
    func mixedSourcesAreNotComparable() {
        let guardian = WorkspaceGuard(processRunner: FakeProcessRunner(standardOutput: ""))
        let gitSnapshot = WorkspaceGuard.Snapshot(digest: "a", source: .git)
        let scanSnapshot = WorkspaceGuard.Snapshot(digest: "b", source: .fileScan)
        // Um repositório que deixou de ser legível pelo git no meio da chamada
        // não é prova de alteração.
        #expect(guardian.verdict(before: gitSnapshot, after: scanSnapshot) == .unavailable)
    }

    @Test("Árvore suja gera aviso antes da chamada")
    func warnsAboutUncommittedWork() throws {
        let fake = ScriptedProcessRunner(
            agyOutput: AgyEnvelopeTests.sample,
            gitOutputs: [" M Sources/x.swift\n", " M Sources/x.swift\n", "abc\n", " M Sources/x.swift\n", "abc\n"]
        )
        let outcome = try makeRunner(fake).run(inspectRequest())
        #expect(outcome.warnings.contains { $0.contains("não commitado") })
        // A árvore não mudou durante a chamada: só o aviso prévio.
        #expect(!outcome.warnings.contains { $0.contains("foi alterado") })
    }

    @Test("O git roda com ambiente controlado")
    func gitEnvironmentIsControlled() throws {
        let fake = ScriptedProcessRunner(agyOutput: AgyEnvelopeTests.sample, gitOutputs: ["", "", "a\n", "", "a\n"])
        _ = try makeRunner(fake).run(inspectRequest())
        let gitPlan = try #require(fake.plans.first { $0.executable.lastPathComponent == "git" })
        #expect(gitPlan.environment["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(gitPlan.environment["NO_COLOR"] == "1")
        #expect(gitPlan.workingDirectory == Self.repo.root)
    }
}

@Suite("Avisos do agy em stderr")
struct AgyWarningTests {
    @Test("Avisos são extraídos do stderr mesmo em chamada bem-sucedida")
    func extractsWarnings() {
        let stderr = "warning: --mode plan has no effect while slash command expansion is disabled.\noutra linha\n"
        let warnings = AgyRunner.warnings(inStandardError: stderr)
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("--mode plan has no effect"))
    }

    @Test("stderr sem avisos não produz ruído")
    func noWarnings() {
        #expect(AgyRunner.warnings(inStandardError: "").isEmpty)
        #expect(AgyRunner.warnings(inStandardError: "linha qualquer\n").isEmpty)
    }

    @Test("O aviso chega ao resultado da delegação")
    func warningReachesOutcome() throws {
        let fake = FakeProcessRunner(
            standardOutput: AgyEnvelopeTests.sample,
            standardError: "warning: algo inesperado\n"
        )
        let runner = AgyRunner(
            executable: URL(filePath: "/bin/agy", directoryHint: .notDirectory),
            agyVersion: "1.2.7",
            processRunner: fake,
            parentEnvironment: [:]
        )
        let outcome = try runner.run(AgyInvocationTests.request())
        #expect(outcome.warnings == ["agy: warning: algo inesperado"])
    }
}
