import Foundation

/// Instalação reversível do provider local do Codex.
public struct CodexInstaller: Sendable {
    public static let managedStart = "# BEGIN AGY CODEX PROVIDER"
    public static let managedEnd = "# END AGY CODEX PROVIDER"
    public static let launchLabel = "local.agy-agent.codex"
    public static let legacyLaunchLabel = "br.ufrj.agy-agent.codex"
    public let homeDirectory: URL
    public let executableName: String

    public init(homeDirectory: URL, executableName: String = "agy-agent") {
        self.homeDirectory = DirectoryURL.normalized(homeDirectory); self.executableName = executableName
    }

    public var codexDirectory: URL { homeDirectory.appending(path: ".codex") }
    public var configURL: URL { codexDirectory.appending(path: "config.toml") }
    public var agentsDirectory: URL { codexDirectory.appending(path: "agents") }
    public var antigravityAgentsDirectory: URL { homeDirectory.appending(path: ".gemini/config/agents") }
    public var antigravityReaderURL: URL { antigravityAgentsDirectory.appending(path: "agy-leitor.md") }
    public var launchAgentsDirectory: URL { homeDirectory.appending(path: "Library/LaunchAgents") }
    public var launchAgentURL: URL { launchAgentsDirectory.appending(path: "\(Self.launchLabel).plist") }
    public var legacyLaunchAgentURL: URL { launchAgentsDirectory.appending(path: "\(Self.legacyLaunchLabel).plist") }
    public var installedExecutable: URL { homeDirectory.appending(path: ".local/bin/\(executableName)") }
    public var executableMarker: URL { installedExecutable.deletingLastPathComponent().appending(path: ".agy-agent-codex-managed") }
    public var executableBackup: URL { installedExecutable.deletingLastPathComponent().appending(path: ".\(executableName).pre-codex") }
    public var installedResourceBundle: URL { installedExecutable.deletingLastPathComponent().appending(path: "agy-agent_AgyAgentKit.bundle") }
    public var resourceBundleBackup: URL { installedExecutable.deletingLastPathComponent().appending(path: ".agy-agent_AgyAgentKit.pre-codex.bundle") }
    public var providerTokenURL: URL { homeDirectory.appending(path: ".config/agy-agent/provider-token") }
    public var healthURL: String { "http://127.0.0.1:\(CodexProxyServer.defaultPort)/health" }
    public var displayBaseURL: String { "http://127.0.0.1:\(CodexProxyServer.defaultPort)/<token>/v1" }

    public func enable(sourceExecutable: URL) throws -> [String] {
        guard FileManager.default.isExecutableFile(atPath: sourceExecutable.path(percentEncoded: false)) else { throw AgyAgentError.storeFailed("executável inexistente: \(sourceExecutable.path)") }
        let sourceResourceBundle = sourceExecutable.deletingLastPathComponent().appending(path: "agy-agent_AgyAgentKit.bundle")
        var isResourceDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceResourceBundle.path(percentEncoded: false), isDirectory: &isResourceDirectory), isResourceDirectory.boolValue else {
            throw AgyAgentError.storeFailed("bundle de recursos não encontrado: \(sourceResourceBundle.path)")
        }
        try FileManager.default.createDirectory(at: installedExecutable.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let existingMarker = String(
            decoding: FileManager.default.contents(atPath: executableMarker.path(percentEncoded: false)) ?? Data(),
            as: UTF8.self
        )
        let installationIsManaged = !existingMarker.isEmpty
        var rollbackExecutable: URL?
        var rollbackResourceBundle: URL?
        if installationIsManaged {
            let rollback = installedExecutable.deletingLastPathComponent()
                .appending(path: ".agy-agent.rollback-\(UUID().uuidString)")
            do {
                try FileManager.default.copyItem(at: installedExecutable, to: rollback)
                rollbackExecutable = rollback
                if FileManager.default.fileExists(atPath: installedResourceBundle.path(percentEncoded: false)) {
                    let bundleRollback = installedResourceBundle.deletingLastPathComponent()
                        .appending(path: ".agy-agent-resources.rollback-\(UUID().uuidString)")
                    rollbackResourceBundle = bundleRollback
                    try FileManager.default.copyItem(at: installedResourceBundle, to: bundleRollback)
                }
            } catch {
                try? FileManager.default.removeItem(at: rollback)
                if let rollbackResourceBundle { try? FileManager.default.removeItem(at: rollbackResourceBundle) }
                throw error
            }
        }
        let tokenExisted = FileManager.default.fileExists(atPath: providerTokenURL.path(percentEncoded: false))
        let originalConfig = FileManager.default.contents(atPath: configURL.path(percentEncoded: false))
        let originalReader = FileManager.default.contents(atPath: antigravityReaderURL.path(percentEncoded: false))
        let originalLaunchAgent = FileManager.default.contents(atPath: launchAgentURL.path(percentEncoded: false))
        let originalLegacyLaunchAgent = FileManager.default.contents(atPath: legacyLaunchAgentURL.path(percentEncoded: false))
        let originalDispatchers = Dictionary(uniqueKeysWithValues: CodexRole.allCases.compactMap { role in
            let url = agentsDirectory.appending(path: "\(role.rawValue).toml")
            return FileManager.default.contents(atPath: url.path(percentEncoded: false)).map { (url, $0) }
        })
        var executableBackupPath = markerValue("executable_backup", in: existingMarker)
        var resourceBackupPath = markerValue("resource_backup", in: existingMarker)
        if !installationIsManaged,
           let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: installedExecutable.path(percentEncoded: false)) {
            guard !FileManager.default.fileExists(atPath: executableBackup.path(percentEncoded: false)) else { throw AgyAgentError.storeFailed("backup do executável já existe; disable a instalação anterior primeiro") }
            try FileManager.default.moveItem(at: installedExecutable, to: executableBackup)
            executableBackupPath = executableBackup.path(percentEncoded: false)
            _ = existing
        }
        if !installationIsManaged,
           FileManager.default.fileExists(atPath: installedResourceBundle.path(percentEncoded: false)) {
            guard !FileManager.default.fileExists(atPath: resourceBundleBackup.path(percentEncoded: false)) else { throw AgyAgentError.storeFailed("backup do bundle já existe; disable a instalação anterior primeiro") }
            try FileManager.default.moveItem(at: installedResourceBundle, to: resourceBundleBackup)
            resourceBackupPath = resourceBundleBackup.path(percentEncoded: false)
        }
        do {
            let providerToken = try ensureProviderToken()
            try installAtomicCopy(from: sourceExecutable, to: installedExecutable)
            try installAtomicDirectory(from: sourceResourceBundle, to: installedResourceBundle)
            try Data("managed by codex-enable\nexecutable_backup=\(executableBackupPath ?? "")\nresource_backup=\(resourceBackupPath ?? "")\n".utf8).write(to: executableMarker, options: .atomic)
            try updateConfig(enabled: true, providerBaseURL: protectedBaseURL(token: providerToken))
            try removeManagedDispatchers()
            try FileManager.default.createDirectory(at: antigravityAgentsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try writeAntigravityReader()
            try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try writeLaunchAgent()
            _ = launchctl(["bootout", "gui/\(getuid())/\(Self.launchLabel)"])
            _ = launchctl(["bootstrap", "gui/\(getuid())", launchAgentURL.path(percentEncoded: false)])
            try removeLegacyLaunchAgent()
            if let rollbackExecutable { try? FileManager.default.removeItem(at: rollbackExecutable) }
            if let rollbackResourceBundle { try? FileManager.default.removeItem(at: rollbackResourceBundle) }
            return [installedExecutable.path(percentEncoded: false), configURL.path(percentEncoded: false), launchAgentURL.path(percentEncoded: false)]
        } catch {
            if installationIsManaged, let rollbackExecutable {
                try? FileManager.default.removeItem(at: installedExecutable)
                try? FileManager.default.moveItem(at: rollbackExecutable, to: installedExecutable)
                try? FileManager.default.removeItem(at: installedResourceBundle)
                if let rollbackResourceBundle {
                    try? FileManager.default.moveItem(at: rollbackResourceBundle, to: installedResourceBundle)
                }
                try? Data(existingMarker.utf8).write(to: executableMarker, options: .atomic)
            } else if executableBackupPath != nil {
                try? FileManager.default.removeItem(at: installedExecutable)
                try? FileManager.default.moveItem(at: executableBackup, to: installedExecutable)
            } else if FileManager.default.fileExists(atPath: installedExecutable.path(percentEncoded: false)) {
                try? FileManager.default.removeItem(at: installedExecutable)
            }
            if !installationIsManaged {
                try? FileManager.default.removeItem(at: installedResourceBundle)
                if resourceBackupPath != nil {
                    try? FileManager.default.moveItem(at: resourceBundleBackup, to: installedResourceBundle)
                }
                try? FileManager.default.removeItem(at: executableMarker)
            }
            if !tokenExisted { try? FileManager.default.removeItem(at: providerTokenURL) }
            restore(originalConfig, to: configURL)
            restore(originalReader, to: antigravityReaderURL)
            restore(originalLaunchAgent, to: launchAgentURL)
            restore(originalLegacyLaunchAgent, to: legacyLaunchAgentURL)
            for (url, data) in originalDispatchers { restore(data, to: url) }
            throw error
        }
    }

    public func disable() throws {
        try removeLegacyLaunchAgent()
        if let data = FileManager.default.contents(atPath: launchAgentURL.path(percentEncoded: false)),
           String(decoding: data, as: UTF8.self).contains(Self.launchLabel),
           String(decoding: data, as: UTF8.self).contains("codex-proxy") {
            _ = launchctl(["bootout", "gui/\(getuid())/\(Self.launchLabel)"])
            try FileManager.default.removeItem(at: launchAgentURL)
        }
        try updateConfig(enabled: false)
        if FileManager.default.fileExists(atPath: executableMarker.path(percentEncoded: false)) {
            let marker = String(decoding: FileManager.default.contents(atPath: executableMarker.path(percentEncoded: false)) ?? Data(), as: UTF8.self)
            try? FileManager.default.removeItem(at: installedExecutable)
            try? FileManager.default.removeItem(at: installedResourceBundle)
            if let backupPath = markerValue("executable_backup", in: marker), FileManager.default.fileExists(atPath: backupPath) {
                try FileManager.default.moveItem(at: URL(filePath: backupPath, directoryHint: .notDirectory), to: installedExecutable)
            }
            if let backupPath = markerValue("resource_backup", in: marker), FileManager.default.fileExists(atPath: backupPath) {
                try FileManager.default.moveItem(at: URL(filePath: backupPath, directoryHint: .isDirectory), to: installedResourceBundle)
            }
            try FileManager.default.removeItem(at: executableMarker)
            try? FileManager.default.removeItem(at: providerTokenURL)
        }
        try removeManagedDispatchers()
        if let data = FileManager.default.contents(atPath: antigravityReaderURL.path(percentEncoded: false)), String(decoding: data, as: UTF8.self).contains("# AGY CODEX MANAGED") { try FileManager.default.removeItem(at: antigravityReaderURL) }
    }

    public func status() -> (provider: Bool, mcp: Bool, launchAgent: Bool, agents: [String], executable: Bool) {
        let config = String(decoding: FileManager.default.contents(atPath: configURL.path(percentEncoded: false)) ?? Data(), as: UTF8.self)
        let agents = CodexRole.allCases.filter { FileManager.default.fileExists(atPath: agentsDirectory.appending(path: "\($0.rawValue).toml").path(percentEncoded: false)) }.map(\.rawValue)
        return (
            config.contains(Self.managedStart) && config.contains("model_providers.antigravity"),
            config.contains(Self.managedStart) && config.contains("mcp_servers.agy-agent"),
            FileManager.default.fileExists(atPath: launchAgentURL.path(percentEncoded: false)),
            agents,
            FileManager.default.fileExists(atPath: executableMarker.path(percentEncoded: false)) && FileManager.default.isExecutableFile(atPath: installedExecutable.path(percentEncoded: false))
        )
    }

    public func launchAgentIsLoaded() -> Bool {
        launchctl(["print", "gui/\(getuid())/\(Self.launchLabel)"])?.exitCode == 0
    }

    public func providerToken() throws -> String {
        let token = String(decoding: try Data(contentsOf: providerTokenURL), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let validCharacters = Set("0123456789abcdef")
        let valid = token.count == 64 && token.allSatisfy { validCharacters.contains($0) }
        guard valid else { throw AgyAgentError.invalidConfiguration("token do provider ausente ou inválido") }
        return token
    }

    public func protectedBaseURL(token: String) -> String {
        "http://127.0.0.1:\(CodexProxyServer.defaultPort)/\(token)/v1"
    }

    public static func providerBlock(baseURL: String, executable: String) -> String {
        let escapedExecutable = executable
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        \(managedStart)
        [model_providers.antigravity]
        name = "Local Antigravity bridge"
        base_url = "\(baseURL)"
        wire_api = "responses"
        request_max_retries = 0
        stream_max_retries = 0

        [mcp_servers.agy-agent]
        command = "\(escapedExecutable)"
        args = ["mcp-serve"]
        startup_timeout_sec = 10
        tool_timeout_sec = 45
        \(managedEnd)
        """
    }

    private func updateConfig(enabled: Bool, providerBaseURL: String? = nil) throws {
        let existing = String(decoding: FileManager.default.contents(atPath: configURL.path(percentEncoded: false)) ?? Data(), as: UTF8.self)
        var retained = existing
        guard !retained.contains(Self.managedEnd) || retained.range(of: Self.managedStart) != nil else {
            throw AgyAgentError.invalidConfiguration("bloco gerenciado do provider Codex incompleto")
        }
        while let start = retained.range(of: Self.managedStart) {
            guard let end = retained.range(of: Self.managedEnd, range: start.upperBound..<retained.endIndex) else {
                throw AgyAgentError.invalidConfiguration("bloco gerenciado do provider Codex incompleto")
            }
            guard !retained[start.upperBound..<end.lowerBound].contains(Self.managedStart) else {
                throw AgyAgentError.invalidConfiguration("blocos gerenciados do provider Codex aninhados")
            }
            retained.removeSubrange(start.lowerBound..<end.upperBound)
        }
        let backup = configURL.appendingPathExtension("bak-\(Int(Date().timeIntervalSince1970))")
        if FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)) {
            try? Data(existing.utf8).write(to: backup, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path(percentEncoded: false))
        }
        let content: String
        if enabled {
            guard let providerBaseURL else { throw AgyAgentError.invalidConfiguration("URL protegida do provider ausente") }
            let separator = retained.isEmpty || retained.hasSuffix("\n") ? "" : "\n"
            content = retained + separator + "\n" + Self.providerBlock(
                baseURL: providerBaseURL,
                executable: installedExecutable.path(percentEncoded: false)
            ) + "\n"
        } else {
            content = retained
        }
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(content.utf8).write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path(percentEncoded: false))
    }

    private func ensureProviderToken() throws -> String {
        if FileManager.default.fileExists(atPath: providerTokenURL.path(percentEncoded: false)) {
            return try providerToken()
        }
        try FileManager.default.createDirectory(
            at: providerTokenURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var generator = SystemRandomNumberGenerator()
        let token = (0..<32).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
        do {
            try Data((token + "\n").utf8).write(to: providerTokenURL, options: .withoutOverwriting)
        } catch {
            if FileManager.default.fileExists(atPath: providerTokenURL.path(percentEncoded: false)) {
                return try providerToken()
            }
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: providerTokenURL.path(percentEncoded: false))
        return token
    }

    private func removeManagedDispatchers() throws {
        for role in CodexRole.allCases {
            let url = agentsDirectory.appending(path: "\(role.rawValue).toml")
            guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)),
                  String(decoding: data, as: UTF8.self).contains("# AGY CODEX MANAGED") else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func writeLaunchAgent() throws {
        if let existing = FileManager.default.contents(atPath: launchAgentURL.path(percentEncoded: false)) {
            let text = String(decoding: existing, as: UTF8.self)
            guard text.contains(Self.launchLabel), text.contains("codex-proxy") else {
                throw AgyAgentError.storeFailed("LaunchAgent existente não é gerenciado: \(launchAgentURL.path)")
            }
        }
        let executable = installedExecutable.path(percentEncoded: false).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(Self.launchLabel)</string>
        <key>ProgramArguments</key><array><string>\(executable)</string><string>codex-proxy</string></array>
        <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
        <key>LimitLoadToSessionType</key><string>Aqua</string>
        </dict></plist>
        """
        try Data(plist.utf8).write(to: launchAgentURL, options: .atomic)
    }

    private func removeLegacyLaunchAgent() throws {
        guard let data = FileManager.default.contents(atPath: legacyLaunchAgentURL.path(percentEncoded: false)) else { return }
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains(Self.legacyLaunchLabel), text.contains("codex-proxy") else { return }
        _ = launchctl(["bootout", "gui/\(getuid())/\(Self.legacyLaunchLabel)"])
        try FileManager.default.removeItem(at: legacyLaunchAgentURL)
    }

    private func writeAntigravityReader() throws {
        if let existing = FileManager.default.contents(atPath: antigravityReaderURL.path(percentEncoded: false)),
           !String(decoding: existing, as: UTF8.self).contains("# AGY CODEX MANAGED") {
            throw AgyAgentError.storeFailed("agente existente não é gerenciado: \(antigravityReaderURL.path)")
        }
        let text = """
        ---
        # AGY CODEX MANAGED
        name: agy-leitor
        description: agente somente leitura para exploração e revisão
        tools:
          - view_file
          - grep_search
        subagent: true
        mainAgent: false
        model: flash
        commandExecutionPolicy: sandbox
        ---
        # Leitura factual

        Leia e pesquise arquivos do workspace. Não execute comandos, não crie,
        edite, remova nem mova arquivos. Devolva apenas evidências, caminhos,
        linhas relevantes e limitações verificáveis.
        """
        try Data(text.utf8).write(to: antigravityReaderURL, options: .atomic)
    }

    private func restore(_ data: Data?, to url: URL) {
        if let data {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func installAtomicCopy(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let temp = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try manager.copyItem(at: source, to: temp)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temp.path(percentEncoded: false))
        if let existing = try? manager.destinationOfSymbolicLink(atPath: destination.path(percentEncoded: false)) {
            let resolved = URL(filePath: existing, relativeTo: destination.deletingLastPathComponent()).standardizedFileURL.path(percentEncoded: false)
            guard resolved.hasSuffix("/agy-agent") || resolved.contains("/.build/") else { throw AgyAgentError.storeFailed("\(destination.path) é um link não gerenciado") }
            try manager.removeItem(at: destination)
        }
        else if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            guard manager.fileExists(atPath: executableMarker.path(percentEncoded: false)) else { throw AgyAgentError.storeFailed("\(destination.path) existe e não é um link gerenciado") }
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: temp, to: destination)
    }

    private func installAtomicDirectory(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let temp = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try manager.copyItem(at: source, to: temp)
        if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: temp, to: destination)
    }

    private func markerValue(_ key: String, in marker: String) -> String? {
        guard let line = marker.split(separator: "\n").first(where: { $0.hasPrefix("\(key)=") }) else { return nil }
        let value = String(line.dropFirst(key.count + 1))
        return value.isEmpty ? nil : value
    }

    @discardableResult private func launchctl(_ arguments: [String]) -> ProcessResult? {
        let url = URL(filePath: "/bin/launchctl", directoryHint: .notDirectory)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return try? SubprocessRunner().run(ProcessPlan(executable: url, arguments: arguments, workingDirectory: homeDirectory, environment: ["PATH": "/bin:/usr/bin"], timeout: .seconds(20)))
    }
}
