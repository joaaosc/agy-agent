import Foundation

/// Resolução de caminhos do agy-agent.
///
/// Convenções adotadas:
/// - Configuração e prompts seguem XDG (`XDG_CONFIG_HOME`, padrão `~/.config`),
///   porque são arquivos editados à mão e versionáveis.
/// - Estado durável segue a convenção Apple (`~/Library/Application Support`).
/// - Cache descartável fica em `~/Library/Caches`, separado do estado durável,
///   para que a limpeza do cache nunca destrua conhecimento acumulado.
/// - Logs ficam em `~/Library/Logs`.
///
/// `AGY_AGENT_HOME` redireciona **todas** as raízes para um único diretório.
/// Existe para testes e execuções isoladas; nenhum caminho é criado aqui.
public struct Paths: Sendable, Equatable {
    public static let toolName = "agy-agent"

    public let configDirectory: URL
    public let promptsDirectory: URL
    public let dataDirectory: URL
    public let stateDirectory: URL
    public let cacheDirectory: URL
    public let logDirectory: URL

    public init(
        configDirectory: URL,
        promptsDirectory: URL,
        dataDirectory: URL,
        stateDirectory: URL,
        cacheDirectory: URL,
        logDirectory: URL
    ) {
        self.configDirectory = configDirectory
        self.promptsDirectory = promptsDirectory
        self.dataDirectory = dataDirectory
        self.stateDirectory = stateDirectory
        self.cacheDirectory = cacheDirectory
        self.logDirectory = logDirectory
    }

    /// Arquivo de configuração principal.
    public var configFile: URL { configDirectory.appending(path: "config.toml") }

    /// Base durável: pacotes de evidência promovidos a conhecimento reutilizável.
    public var knowledgeDatabase: URL { dataDirectory.appending(path: "knowledge.sqlite") }

    /// Diário de tentativas — sucesso, cache, erro ou bloqueio. Fica junto do
    /// conhecimento durável, não do cache: é histórico para diagnóstico, não
    /// descartável.
    public var telemetryDatabase: URL { dataDirectory.appending(path: "telemetry.sqlite") }

    /// Base descartável: respostas memoizadas por chave de cache.
    /// Apagar este arquivo deve ser sempre seguro.
    public var cacheDatabase: URL { cacheDirectory.appending(path: "cache.sqlite") }

    public var logFile: URL { logDirectory.appending(path: "agy-agent.log") }

    /// Diretórios que o runtime precisa criar antes de escrever.
    ///
    /// `logDirectory` ficou de fora: nada escreve nele. O registro de cada
    /// delegação já está no store, com tempo, custo e resposta; um arquivo de
    /// log paralelo só acrescentaria crescimento sem limite e mais um lugar
    /// para procurar. Falhas aparecem em stderr no momento em que ocorrem.
    public var writableDirectories: [URL] {
        [dataDirectory, stateDirectory, cacheDirectory]
    }

    /// Cria os diretórios graváveis, com permissão restrita.
    ///
    /// Chamado na primeira delegação, não na inicialização: um comando de
    /// diagnóstico não deve semear diretórios. O `stateDirectory` em
    /// particular é o diretório de trabalho dos modos sem workspace, e um
    /// processo não pode ser lançado em diretório inexistente.
    public func createWritableDirectories() throws {
        for directory in writableDirectories {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw AgyAgentError.storeFailed(
                    "criar \(directory.path(percentEncoded: false)): \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Resolução

    /// Resolve os caminhos a partir do ambiente, sem tocar no sistema de arquivos.
    public static func resolve(
        environment: [String: String],
        homeDirectory: URL
    ) -> Paths {
        if let overrideRoot = absoluteURL(environment["AGY_AGENT_HOME"], relativeTo: homeDirectory) {
            let config = overrideRoot.appending(path: "config")
            return Paths(
                configDirectory: config,
                promptsDirectory: config.appending(path: "prompts"),
                dataDirectory: overrideRoot.appending(path: "data"),
                stateDirectory: overrideRoot.appending(path: "data/state"),
                cacheDirectory: overrideRoot.appending(path: "cache"),
                logDirectory: overrideRoot.appending(path: "logs")
            )
        }

        let home = DirectoryURL.normalized(homeDirectory)
        let xdgConfig = absoluteURL(environment["XDG_CONFIG_HOME"], relativeTo: home)
            ?? home.appending(path: ".config")
        let config = xdgConfig.appending(path: toolName)
        let library = home.appending(path: "Library")

        return Paths(
            configDirectory: config,
            promptsDirectory: config.appending(path: "prompts"),
            dataDirectory: library.appending(path: "Application Support/\(toolName)"),
            stateDirectory: library.appending(path: "Application Support/\(toolName)/state"),
            cacheDirectory: library.appending(path: "Caches/\(toolName)"),
            logDirectory: library.appending(path: "Logs/\(toolName)")
        )
    }

    /// Aceita apenas caminhos absolutos; um valor relativo em variável de ambiente
    /// dependeria do diretório corrente e tornaria a resolução imprevisível.
    static func absoluteURL(_ value: String?, relativeTo homeDirectory: URL) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if value == "~" { return DirectoryURL.normalized(homeDirectory) }
        if value.hasPrefix("~/") {
            return DirectoryURL.normalized(homeDirectory.appending(path: String(value.dropFirst(2))))
        }
        guard value.hasPrefix("/") else { return nil }
        return DirectoryURL.normalized(URL(filePath: value, directoryHint: .isDirectory))
    }
}
