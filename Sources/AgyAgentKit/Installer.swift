import Foundation

/// Instalação e remoção do `agy-agent` no PATH do usuário.
///
/// O link é um symlink para o produto de release, nunca uma cópia: uma cópia
/// ficaria desatualizada em silêncio depois de cada `swift build`, e o
/// sintoma disso — comportamento antigo sem motivo aparente — é caro de
/// diagnosticar.
///
/// Nada aqui toca em `~/.claude.json` nem em `settings.json`. Registrar
/// servidor MCP ou conceder permissão é decisão do usuário, e a instrução
/// correspondente é apenas impressa.
public struct Installer: Sendable {
    public struct Report: Sendable {
        public var linkPath: String
        public var usageLinkPath: String
        public var target: String
        public var created: Bool
        public var replaced: Bool
        public var seededPrompts: [Mode]
        public var wroteConfigTemplate: Bool
        public var pathContainsLinkDirectory: Bool
    }

    private let paths: Paths
    private let homeDirectory: URL

    public init(paths: Paths, homeDirectory: URL) {
        self.paths = paths
        self.homeDirectory = DirectoryURL.normalized(homeDirectory)
    }

    public var linkDirectory: URL { homeDirectory.appending(path: ".local/bin") }
    public var linkURL: URL { linkDirectory.appending(path: "agy-agent") }
    public var usageURL: URL { linkDirectory.appending(path: "usage") }

    public func install(executable: URL, environment: [String: String], installUsageAlias: Bool = false) throws -> Report {
        let manager = FileManager.default
        let target = executable.resolvingSymlinksInPath()
        guard manager.isExecutableFile(atPath: target.path(percentEncoded: false)) else {
            throw AgyAgentError.storeFailed("executável não encontrado: \(target.path(percentEncoded: false))")
        }

        try paths.createWritableDirectories()
        try manager.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        if installUsageAlias { try validateUsageDestination() }

        var created = false
        var replaced = false
        let linkPath = linkURL.path(percentEncoded: false)

        if let existing = try? manager.destinationOfSymbolicLink(atPath: linkPath) {
            if existing == target.path(percentEncoded: false) {
                // Já aponta para o lugar certo: instalar de novo não é erro.
                created = false
            } else {
                try manager.removeItem(at: linkURL)
                try manager.createSymbolicLink(at: linkURL, withDestinationURL: target)
                replaced = true
            }
        } else if manager.fileExists(atPath: linkPath) {
            // Um arquivo comum nesse caminho não é nosso para apagar.
            throw AgyAgentError.storeFailed("\(linkPath) existe e não é um symlink; remova-o antes de instalar")
        } else {
            try manager.createSymbolicLink(at: linkURL, withDestinationURL: target)
            created = true
        }

        if installUsageAlias,
           (try? manager.destinationOfSymbolicLink(atPath: usageURL.path(percentEncoded: false))) == nil {
            try manager.createSymbolicLink(at: usageURL, withDestinationURL: linkURL)
        }

        let library = PromptLibrary(directory: paths.promptsDirectory)
        let seeded = try library.seedMissing()
        let wroteTemplate = try writeConfigTemplateIfMissing()

        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let linkDirectoryPath = DirectoryURL.path(linkDirectory)

        return Report(
            linkPath: linkPath,
            usageLinkPath: usageURL.path(percentEncoded: false),
            target: target.path(percentEncoded: false),
            created: created,
            replaced: replaced,
            seededPrompts: seeded,
            wroteConfigTemplate: wroteTemplate,
            pathContainsLinkDirectory: pathEntries.contains { DirectoryURL.path(AgyLocator.fileURL($0, homeDirectory: homeDirectory)) == linkDirectoryPath }
        )
    }

    /// Remove apenas o link. Configuração, prompts e bancos ficam: desinstalar
    /// não é o mesmo que apagar o que a ferramenta acumulou.
    @discardableResult
    public func uninstall() throws -> Bool {
        let linkPath = linkURL.path(percentEncoded: false)
        let manager = FileManager.default
        var removed = false
        let usageDestination = try? manager.destinationOfSymbolicLink(atPath: usageURL.path(percentEncoded: false))
        let linkDestination = try? manager.destinationOfSymbolicLink(atPath: linkPath)

        // O alias é opcional. Um arquivo ou link alheio chamado `usage` deve
        // ser preservado e não pode impedir a remoção do link principal.
        if linkDestination == nil, manager.fileExists(atPath: linkPath) {
            throw AgyAgentError.storeFailed("\(linkPath) não é um symlink desta ferramenta; não será removido")
        }

        if let destination = usageDestination {
            if isManagedUsageDestination(destination) {
                try manager.removeItem(at: usageURL)
                removed = true
            }
        }

        if linkDestination != nil {
            try manager.removeItem(at: linkURL)
            removed = true
        }
        return removed
    }

    private func validateUsageDestination() throws {
        let manager = FileManager.default
        let path = usageURL.path(percentEncoded: false)
        guard let destination = try? manager.destinationOfSymbolicLink(atPath: path) else {
            guard !manager.fileExists(atPath: path) else {
                throw AgyAgentError.storeFailed("\(path) existe e não é um symlink; remova-o antes de instalar")
            }
            return
        }
        guard isManagedUsageDestination(destination) else {
            throw AgyAgentError.storeFailed("\(path) aponta para outro destino; não será substituído")
        }
    }

    private func isManagedUsageDestination(_ destination: String) -> Bool {
        let destinationURL = URL(
            filePath: destination,
            directoryHint: .notDirectory,
            relativeTo: usageURL.deletingLastPathComponent()
        ).standardizedFileURL
        return destinationURL.path(percentEncoded: false) == linkURL.standardizedFileURL.path(percentEncoded: false)
    }

    private func writeConfigTemplateIfMissing() throws -> Bool {
        let url = paths.configFile
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return false }
        try FileManager.default.createDirectory(
            at: paths.configDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(Self.configTemplate.utf8).write(to: url, options: .withoutOverwriting)
        return true
    }

    /// Modelo comentado: o arquivo existe para ser editado, e todos os valores
    /// já são os padrões, então descomentar não muda comportamento por acidente.
    static let configTemplate = """
        # ~/.config/agy-agent/config.toml
        #
        # Tudo é opcional. Precedência por campo: flag > este arquivo > padrão do modo.
        # Apenas um subconjunto plano de TOML é aceito; o que não for reconhecido
        # é recusado com o número da linha, em vez de ignorado em silêncio.

        # agy_path = "~/.local/bin/agy"
        # model = "gemini-3.8-flash-medium"

        # Freio de gasto: barra a chamada ANTES de ela sair, com base no que
        # já foi gasto nas últimas 5 horas. Protege a cota do Gemini de laços
        # acidentais. Servir do cache nunca é barrado.
        # max_calls_per_window = 40
        # max_agy_tokens_per_window = 2_000_000
        # timeout_seconds = 240
        # response_budget = 2000
        # max_cache_age_seconds = 86_400

        [mode.research]
        # response_budget = 3000

        [mode.inspect]
        # sandbox bloqueia rede e acesso fora do workspace.
        # Não impede escrita dentro dele; a auditoria posterior apenas detecta.
        # sandbox = true

        [mode.verify]
        # response_budget = 1200

        [mode.summarize]
        # max_cache_age_seconds é ignorado: o modo não depende da web.
        """
}
