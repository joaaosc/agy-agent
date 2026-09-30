import Foundation

/// Resultado de uma delegação.
///
/// Os avisos vêm separados da resposta de propósito: a resposta é o que entra
/// no contexto de quem chamou e precisa caber no orçamento; os avisos são
/// para o humano e vão por stderr.
public struct DelegationOutcome: Sendable {
    public var packet: EvidencePacket
    public var warnings: [String]

    public init(packet: EvidencePacket, warnings: [String] = []) {
        self.packet = packet
        self.warnings = warnings
    }
}

/// Executa uma delegação no `agy` e devolve um pacote de evidência.
///
/// O runner não consulta cache nem persiste nada: isso é responsabilidade do
/// store. Aqui só existe a chamada, a verificação do workspace e a conversão
/// do resultado.
public struct AgyRunner: Sendable {
    public let executable: URL
    public let agyVersion: String
    private let processRunner: any ProcessRunning
    private let parentEnvironment: [String: String]
    private let clock: @Sendable () -> Date
    private let guardian: WorkspaceGuard
    /// Quem invocou o processo que hospeda esta chamada. Público porque a
    /// telemetria precisa dele mesmo quando a chamada falha — antes de
    /// existir qualquer `EvidencePacket` para carregá-lo.
    public let caller: Caller

    public init(
        executable: URL,
        agyVersion: String,
        processRunner: any ProcessRunning = SubprocessRunner(),
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        clock: @escaping @Sendable () -> Date = { Date() },
        guardian: WorkspaceGuard? = nil,
        caller: Caller? = nil
    ) {
        self.executable = executable
        self.agyVersion = agyVersion
        self.processRunner = processRunner
        self.parentEnvironment = parentEnvironment
        self.clock = clock
        self.guardian = guardian ?? WorkspaceGuard(processRunner: processRunner)
        self.caller = caller ?? Caller.detect(environment: parentEnvironment)
    }

    public func plan(for request: DelegationRequest) -> ProcessPlan {
        AgyInvocation.plan(for: request, executable: executable, parentEnvironment: parentEnvironment)
    }

    public func run(_ request: DelegationRequest) throws -> DelegationOutcome {
        let request = try request.validated()

        // O workspace é fotografado antes e depois porque nenhuma flag do agy
        // impede escrita nos diretórios anexados. Ver `WorkspaceGuard`.
        var warnings: [String] = []
        var before: WorkspaceGuard.Snapshot?
        if let workspace = request.workspace {
            // Avisar antes importa mais que avisar depois: com a árvore limpa,
            // qualquer escrita indevida se desfaz com um comando.
            if guardian.hasUncommittedWork(in: workspace) {
                warnings.append("o repositório tem trabalho não commitado e a chamada pode escrever nele — considere commitar antes")
            }
            before = guardian.snapshot(of: workspace)
        }

        let result = try processRunner.run(plan(for: request))
        let envelope = try decodeEnvelope(from: result)
        guard envelope.status.isSuccess else {
            throw AgyAgentError.agyFailed(status: envelope.status.rawValue, output: result.standardError)
        }
        guard !envelope.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgyAgentError.emptyResponse(result.standardError)
        }

        warnings += Self.warnings(inStandardError: result.standardError)
        if let workspace = request.workspace, let before {
            let verdict = guardian.verdict(before: before, after: guardian.snapshot(of: workspace))
            if let warning = verdict.warning { warnings.append(warning) }
        }

        let packet = EvidencePacket(
            query: request.query,
            envelope: envelope,
            agyVersion: agyVersion,
            now: clock(),
            budget: request.responseBudget,
            caller: caller
        )
        return DelegationOutcome(packet: packet, warnings: warnings)
    }

    /// Avisos que o `agy` emite em stderr mesmo quando a chamada tem sucesso.
    ///
    /// Ignorá-los custou caro uma vez: `--mode plan has no effect while slash
    /// command expansion is disabled` só aparecia aqui, e a flag estava sendo
    /// passada sem efeito nenhum.
    static func warnings(inStandardError text: String) -> [String] {
        text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().hasPrefix("warning:") || $0.lowercased().hasPrefix("aviso:") }
            .map { "agy: \($0)" }
    }

    /// O envelope sai por stdout. O stderr só entra na mensagem de erro,
    /// porque é onde o `agy` explica falhas de autenticação e de modelo.
    private func decodeEnvelope(from result: ProcessResult) throws -> AgyEnvelope {
        do {
            if let streamed = try? AgyEnvelope.decode(fromStreamOutput: result.standardOutput) {
                return streamed
            }
            return try AgyEnvelope.decode(fromCombinedOutput: result.standardOutput)
        } catch {
            // Saída ilegível com código diferente de zero é falha do `agy`,
            // não formato inesperado: reportar o stderr é mais útil.
            if result.exitCode != 0 {
                throw AgyAgentError.agyFailed(
                    status: "exit \(result.exitCode)",
                    output: result.standardError.isEmpty ? result.standardOutput : result.standardError
                )
            }
            throw error
        }
    }

    /// Lê a versão do `agy`, usada como proveniência do pacote.
    public static func readVersion(
        executable: URL,
        processRunner: any ProcessRunning = SubprocessRunner(),
        workingDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let plan = ProcessPlan(
            executable: executable,
            arguments: ["--version"],
            workingDirectory: workingDirectory,
            environment: AgyInvocation.environment(inheriting: environment),
            timeout: .seconds(20)
        )
        guard let result = try? processRunner.run(plan) else { return "unknown" }
        let version = result.standardOutput
            .split(separator: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return version ?? "unknown"
    }
}
