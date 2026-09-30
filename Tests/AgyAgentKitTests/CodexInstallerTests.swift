import Testing
import Foundation
@testable import AgyAgentKit

@Suite("Instalação do provider Codex")
struct CodexInstallerTests {
    private func sourceExecutable(in directory: borrowing TemporaryDirectory) throws -> URL {
        let sourceDirectory = directory.url.appending(path: "source")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let executable = sourceDirectory.appending(path: "agy-agent")
        try FileManager.default.copyItem(at: URL(filePath: "/bin/echo", directoryHint: .notDirectory), to: executable)
        let bundle = sourceDirectory.appending(path: "agy-agent_AgyAgentKit.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("resource".utf8).write(to: bundle.appending(path: "sentinel"))
        return executable
    }

    @Test("Enable e disable preservam configuração alheia")
    func reversibleInstall() throws {
        let home = try TemporaryDirectory()
        let codex = home.url.appending(path: ".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try Data("model = \"preserve\"\n".utf8).write(to: codex.appending(path: "config.toml"))
        let installer = CodexInstaller(homeDirectory: home.url)
        let source = try sourceExecutable(in: home)
        _ = try installer.enable(sourceExecutable: source)
        #expect(installer.status().provider)
        #expect(installer.status().mcp)
        #expect(installer.status().agents.isEmpty)
        let providerToken = try installer.providerToken()
        #expect(providerToken.count == 64)
        #expect(String(decoding: try Data(contentsOf: installer.configURL), as: UTF8.self).contains("/\(providerToken)/v1"))
        let tokenPermissions = try FileManager.default.attributesOfItem(atPath: installer.providerTokenURL.path)[.posixPermissions] as? NSNumber
        #expect(tokenPermissions?.intValue == 0o600)
        #expect(FileManager.default.fileExists(atPath: installer.installedResourceBundle.appending(path: "sentinel").path))
        #expect(String(decoding: try Data(contentsOf: installer.configURL), as: UTF8.self).contains("model = \"preserve\""))
        try installer.disable()
        #expect(!installer.status().provider)
        #expect(!installer.status().mcp)
        #expect(!installer.status().executable)
        #expect(!FileManager.default.fileExists(atPath: installer.providerTokenURL.path))
        #expect(String(decoding: try Data(contentsOf: installer.configURL), as: UTF8.self).contains("model = \"preserve\""))
    }

    @Test("Enable remove despachantes gerenciados e preserva agentes alheios")
    func removesManagedDispatchers() throws {
        let home = try TemporaryDirectory()
        let installer = CodexInstaller(homeDirectory: home.url)
        let source = try sourceExecutable(in: home)
        try FileManager.default.createDirectory(at: installer.agentsDirectory, withIntermediateDirectories: true)
        try Data("# AGY CODEX MANAGED\n".utf8).write(
            to: installer.agentsDirectory.appending(path: "gemini_worker.toml")
        )
        try Data("name = \"preserve\"\n".utf8).write(
            to: installer.agentsDirectory.appending(path: "gemini_explorer.toml")
        )
        _ = try installer.enable(sourceExecutable: source)

        let config = String(decoding: try Data(contentsOf: installer.configURL), as: UTF8.self)
        #expect(config.contains("[mcp_servers.agy-agent]"))
        #expect(config.contains("args = [\"mcp-serve\"]"))
        #expect(!FileManager.default.fileExists(atPath: installer.agentsDirectory.appending(path: "gemini_worker.toml").path))
        #expect(try String(contentsOf: installer.agentsDirectory.appending(path: "gemini_explorer.toml"), encoding: .utf8) == "name = \"preserve\"\n")
    }

    @Test("Disable restaura symlink pré-existente")
    func restoresExistingSymlink() throws {
        let home = try TemporaryDirectory()
        let bin = home.url.appending(path: ".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appending(path: "agy-agent")
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(filePath: "/bin/sh", directoryHint: .notDirectory))
        let installer = CodexInstaller(homeDirectory: home.url)
        let source = try sourceExecutable(in: home)
        _ = try installer.enable(sourceExecutable: source)
        try installer.disable()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: executable.path) == "/bin/sh")
    }

    @Test("Reativar preserva o backup da instalação original")
    func reenablePreservesOriginalBackup() throws {
        let home = try TemporaryDirectory()
        let bin = home.url.appending(path: ".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appending(path: "agy-agent")
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(filePath: "/bin/sh", directoryHint: .notDirectory))
        let installer = CodexInstaller(homeDirectory: home.url)
        let source = try sourceExecutable(in: home)

        _ = try installer.enable(sourceExecutable: source)
        let token = try installer.providerToken()
        _ = try installer.enable(sourceExecutable: source)
        #expect(try installer.providerToken() == token)
        try installer.disable()

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: executable.path) == "/bin/sh")
    }

    @Test("Enable migra apenas o LaunchAgent legado reconhecido")
    func migratesLegacyLaunchAgent() throws {
        let home = try TemporaryDirectory()
        let installer = CodexInstaller(homeDirectory: home.url)
        try FileManager.default.createDirectory(at: installer.launchAgentsDirectory, withIntermediateDirectories: true)
        try Data("<string>\(CodexInstaller.legacyLaunchLabel)</string><string>codex-proxy</string>".utf8)
            .write(to: installer.legacyLaunchAgentURL)
        _ = try installer.enable(sourceExecutable: sourceExecutable(in: home))
        #expect(!FileManager.default.fileExists(atPath: installer.legacyLaunchAgentURL.path))
        #expect(FileManager.default.fileExists(atPath: installer.launchAgentURL.path))
    }

    @Test("Enable recusa arquivo externo no caminho gerenciado e reverte configuração")
    func refusesForeignManagedPath() throws {
        let home = try TemporaryDirectory()
        let installer = CodexInstaller(homeDirectory: home.url)
        try FileManager.default.createDirectory(at: installer.antigravityReaderURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("conteúdo do usuário\n".utf8).write(to: installer.antigravityReaderURL)
        try FileManager.default.createDirectory(at: installer.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"preserve\"\n".utf8).write(to: installer.configURL)

        #expect(throws: AgyAgentError.self) {
            try installer.enable(sourceExecutable: sourceExecutable(in: home))
        }
        #expect(try String(contentsOf: installer.antigravityReaderURL, encoding: .utf8) == "conteúdo do usuário\n")
        #expect(try String(contentsOf: installer.configURL, encoding: .utf8) == "model = \"preserve\"\n")
        #expect(!FileManager.default.fileExists(atPath: installer.executableMarker.path))
    }

    @Test("Falha de reativação restaura a versão gerenciada anterior")
    func failedReenableRestoresManagedVersion() throws {
        let home = try TemporaryDirectory()
        let installer = CodexInstaller(homeDirectory: home.url)
        let source = try sourceExecutable(in: home)
        _ = try installer.enable(sourceExecutable: source)
        let installedBefore = try Data(contentsOf: installer.installedExecutable)
        let configBefore = try Data(contentsOf: installer.configURL)

        try FileManager.default.removeItem(at: source)
        try FileManager.default.copyItem(at: URL(filePath: "/bin/cat", directoryHint: .notDirectory), to: source)
        try Data("arquivo alheio\n".utf8).write(to: installer.launchAgentURL, options: .atomic)

        #expect(throws: AgyAgentError.self) { try installer.enable(sourceExecutable: source) }
        #expect(try Data(contentsOf: installer.installedExecutable) == installedBefore)
        #expect(try Data(contentsOf: installer.configURL) == configBefore)
        #expect(FileManager.default.fileExists(atPath: installer.executableMarker.path))
        #expect(try String(contentsOf: installer.launchAgentURL, encoding: .utf8) == "arquivo alheio\n")
    }

    @Test("Bloco gerenciado incompleto falha fechado e preserva bytes")
    func rejectsIncompleteBlock() throws {
        let home = try TemporaryDirectory()
        let config = home.url.appending(path: ".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "prefix = \"á\"\n\(CodexInstaller.managedStart)\n"
        try Data(original.utf8).write(to: config)
        let installer = CodexInstaller(homeDirectory: home.url)
        let source = try sourceExecutable(in: home)
        #expect(throws: AgyAgentError.self) { try installer.enable(sourceExecutable: source) }
        #expect(String(decoding: try Data(contentsOf: config), as: UTF8.self) == original)
        #expect(!FileManager.default.fileExists(atPath: installer.installedExecutable.path))
        #expect(!FileManager.default.fileExists(atPath: installer.executableMarker.path))
    }

    @Test("Bloco gerenciado sem início também falha fechado")
    func rejectsOrphanEndMarker() throws {
        let home = try TemporaryDirectory()
        let config = home.url.appending(path: ".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "prefix = \"preserve\"\n\(CodexInstaller.managedEnd)\n"
        try Data(original.utf8).write(to: config)
        let installer = CodexInstaller(homeDirectory: home.url)
        let source = try sourceExecutable(in: home)
        #expect(throws: AgyAgentError.self) { try installer.enable(sourceExecutable: source) }
        #expect(String(decoding: try Data(contentsOf: config), as: UTF8.self) == original)
    }
}
