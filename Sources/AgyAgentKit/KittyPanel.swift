import Foundation

/// Abertura automática de uma aba do kitty com o painel ao vivo (`agy-agent
/// watch`), disparada quando o usuário chama `claude` ou `codex`.
///
/// Verificado empiricamente (kitty 0.47.4): `kitty @ launch --type=tab
/// --location=after --cwd=current` cria a aba ao lado da atual, herdando o
/// diretório corrente sem precisar de `--source-window` explícito. A aba não
/// tem shell interativo, então o título passado em `--tab-title` não é
/// sobrescrito por sequências OSC do prompt — fica estável para o `kitty @
/// ls` reencontrar depois.
public struct KittyPanel: Sendable {
    /// Título fixo da aba; é a chave usada para não abrir duas.
    public static let tabTitle = "agy-agent"

    public enum Availability: Sendable, Equatable {
        /// Fora do kitty, ou o binário `kitty` não está no PATH.
        case unavailable(String)
        /// Já existe uma aba com o título — nada foi feito.
        case alreadyOpen
        /// Uma aba nova foi lançada.
        case opened
        /// Kitty está disponível, mas o comando de lançamento falhou.
        case failed(String)
    }

    private let processRunner: any ProcessRunning
    private let isExecutable: @Sendable (URL) -> Bool

    public init(
        processRunner: any ProcessRunning = SubprocessRunner(),
        isExecutable: @escaping @Sendable (URL) -> Bool = { url in
            FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false))
        }
    ) {
        self.processRunner = processRunner
        self.isExecutable = isExecutable
    }

    /// Garante que a aba exista, sem duplicar.
    ///
    /// Silencioso por natureza: chamado de um wrapper de shell antes de
    /// `claude`/`codex` iniciarem, uma falha aqui nunca deve atrapalhar o
    /// início da sessão real. Quem chama decide o que fazer com o resultado.
    public func ensureOpen(
        environment: [String: String],
        workingDirectory: URL,
        panelCommand: [String],
        timeout: Duration = .seconds(5)
    ) -> Availability {
        guard environment["KITTY_LISTEN_ON"] != nil else {
            return .unavailable("fora de uma janela kitty (KITTY_LISTEN_ON ausente)")
        }
        guard let kitty = locateKitty(environment: environment) else {
            return .unavailable("binário kitty não encontrado no PATH")
        }

        switch tabState(kitty: kitty, environment: environment, workingDirectory: workingDirectory, timeout: timeout) {
        case .open:
            return .alreadyOpen
        case .unknown:
            // `kitty @ ls` falhou — não sabemos se já existe. Tentar abrir é
            // mais seguro que desistir: na pior hipótese, uma aba duplicada
            // é um incômodo visual, não uma falha funcional.
            break
        case .absent:
            break
        }

        let arguments = [
            "@", "launch",
            "--type=tab",
            "--tab-title=\(Self.tabTitle)",
            "--location=after",
            "--keep-focus",
            "--cwd=current",
        ] + panelCommand

        let plan = ProcessPlan(
            executable: kitty,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout
        )
        guard let result = try? processRunner.run(plan) else {
            return .failed("não foi possível executar kitty @ launch")
        }
        guard result.exitCode == 0 else {
            return .failed(result.standardError.isEmpty ? "kitty @ launch retornou \(result.exitCode)" : result.standardError)
        }
        return .opened
    }

    // MARK: - Estado da aba

    enum TabState: Equatable { case open, absent, unknown }

    func tabState(
        kitty: URL,
        environment: [String: String],
        workingDirectory: URL,
        timeout: Duration
    ) -> TabState {
        let plan = ProcessPlan(
            executable: kitty,
            arguments: ["@", "ls"],
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout
        )
        guard let result = try? processRunner.run(plan), result.exitCode == 0 else { return .unknown }
        return Self.containsTab(titled: Self.tabTitle, inLsOutput: result.standardOutput) ? .open : .absent
    }

    /// Procura o título entre as abas de todas as janelas do SO.
    ///
    /// Análise estrutural do JSON (não `contains` na string bruta): o título
    /// de uma janela comum poderia coincidir com o texto por acidente.
    static func containsTab(titled title: String, inLsOutput output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return false
        }
        for window in osWindows {
            guard let tabs = window["tabs"] as? [[String: Any]] else { continue }
            if tabs.contains(where: { ($0["title"] as? String) == title }) { return true }
        }
        return false
    }

    // MARK: - Localização do kitty

    func locateKitty(environment: [String: String]) -> URL? {
        for directory in (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(filePath: String(directory), directoryHint: .isDirectory).appending(path: "kitty")
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }
}
