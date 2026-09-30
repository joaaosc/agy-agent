import Foundation
import Testing
@testable import AgyAgentKit

@Suite("Comando de uso")
struct UsageCommandTests {
    @Test("Renderer produz exatamente três linhas e mantém fallback honesto")
    func rendersThreeLines() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let primary = UsageWindow.RateLimitSnapshot(
            usedPercent: 42,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(1_000),
            timestamp: now
        )
        let window = UsageWindow.Result(
            start: now.addingTimeInterval(-3_600),
            end: now,
            bySource: [:],
            unreadableFiles: [],
            firstTurn: nil,
            rateLimits: UsageWindow.RateLimits(primary: primary, secondary: nil, timestamp: now),
            firstTurnBySource: [.claudeCode: now.addingTimeInterval(-3_600)]
        )
        let lines = UsageRenderer.render(window: window, externalTokens: 250, maxExternalTokens: 1_000, now: now)
            .split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].contains("estimativa local"))
        #expect(lines[1].contains("58,0%") || lines[1].contains("58.0%"))
        #expect(lines[2].contains("250/1 000"))
    }

    @Test("Renderer mostra extrapolação do teto sem mascarar o percentual")
    func rendersOverLimitUsage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = UsageWindow.Result(start: now, end: now, bySource: [:], unreadableFiles: [], firstTurn: nil)
        let output = UsageRenderer.render(window: window, externalTokens: 1_500, maxExternalTokens: 1_000, now: now)
        #expect(output.contains("150,0%") || output.contains("150.0%"))
        #expect(output.contains("[████████████]"))
    }

    @Test("Alias usage é roteado pelo argv[0]")
    func routesAlias() {
        #expect(CommandRouting.arguments(for: ["/tmp/usage"]) == ["usage"])
        #expect(CommandRouting.arguments(for: ["/tmp/agy-agent", "usage"]) == ["usage"])
        #expect(CommandRouting.arguments(for: ["/tmp/agy-agent", "report"]) == ["report"])
    }

    @Test("stdin preserva metacaracteres e quebras de linha")
    func passesStdin() throws {
        let directory = try TemporaryDirectory()
        let jobs = try MCPJobManager(
            executable: URL(filePath: "/bin/sh", directoryHint: .notDirectory),
            workingDirectory: directory.url,
            outputDirectory: directory.url.appending(path: "jobs"),
            environment: ["PATH": "/usr/bin:/bin"]
        )
        let task = Data("$(touch should-not-exist)\nlinha\n; echo falso".utf8)
        let spawned = try jobs.spawn(arguments: ["-c", "cat"], label: "stdin", stdin: task)
        let privateInputs = try FileManager.default.contentsOfDirectory(at: directory.url.appending(path: "jobs"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "stdin" }
        #expect(privateInputs.isEmpty)
        while try jobs.status(id: spawned.id).state == .running { Thread.sleep(forTimeInterval: 0.01) }
        guard case .completed(_, let output) = try jobs.collect(id: spawned.id) else {
            Issue.record("job deveria ter concluído")
            return
        }
        #expect(output == task)
        #expect(!FileManager.default.fileExists(atPath: directory.url.appending(path: "should-not-exist").path))
    }

    @Test("stdin rejeita limite e NUL")
    func validatesStdin() throws {
        let directory = try TemporaryDirectory()
        let jobs = try MCPJobManager(
            executable: URL(filePath: "/bin/sh", directoryHint: .notDirectory),
            workingDirectory: directory.url,
            outputDirectory: directory.url.appending(path: "jobs"),
            environment: ["PATH": "/usr/bin:/bin"]
        )
        #expect(throws: MCPJobManager.ManagerError.self) {
            try jobs.spawn(arguments: ["-c", "cat"], label: "too-large", stdin: Data(repeating: 1, count: MCPJobManager.maximumInputBytes + 1))
        }
        #expect(throws: MCPJobManager.ManagerError.self) {
            try jobs.spawn(arguments: ["-c", "cat"], label: "nul", stdin: Data([65, 0, 66]))
        }
    }
}

@Suite("Alias instalado")
struct InstalledUsageAliasTests {
    @Test("Instala e remove apenas o symlink gerenciado")
    func installsAndUninstallsAlias() throws {
        let directory = try TemporaryDirectory()
        let paths = Paths.resolve(environment: ["AGY_AGENT_HOME": directory.url.path], homeDirectory: directory.url)
        let installer = Installer(paths: paths, homeDirectory: directory.url)
        let executable = directory.url.appending(path: "agy-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        _ = try installer.install(executable: executable, environment: [:], installUsageAlias: true)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: installer.usageURL.path) == installer.linkURL.path)
        #expect(try installer.uninstall())
        #expect(!FileManager.default.fileExists(atPath: installer.usageURL.path))
    }

    @Test("Desinstalação valida o link principal antes do alias")
    func validatesBeforeRemovingAlias() throws {
        let directory = try TemporaryDirectory()
        let paths = Paths.resolve(environment: ["AGY_AGENT_HOME": directory.url.path], homeDirectory: directory.url)
        let installer = Installer(paths: paths, homeDirectory: directory.url)
        let executable = directory.url.appending(path: "agy-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        _ = try installer.install(executable: executable, environment: [:], installUsageAlias: true)
        try FileManager.default.removeItem(at: installer.linkURL)
        try Data("owned by user".utf8).write(to: installer.linkURL)

        #expect(throws: AgyAgentError.self) { try installer.uninstall() }
        #expect(FileManager.default.fileExists(atPath: installer.usageURL.path))
        #expect(try String(contentsOf: installer.linkURL, encoding: .utf8) == "owned by user")
    }

    @Test("Desinstalação preserva alias apontando para outro destino")
    func preservesForeignAlias() throws {
        let directory = try TemporaryDirectory()
        let paths = Paths.resolve(environment: ["AGY_AGENT_HOME": directory.url.path], homeDirectory: directory.url)
        let installer = Installer(paths: paths, homeDirectory: directory.url)
        let executable = directory.url.appending(path: "agy-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        _ = try installer.install(executable: executable, environment: [:], installUsageAlias: true)
        try FileManager.default.removeItem(at: installer.usageURL)
        try FileManager.default.createSymbolicLink(atPath: installer.usageURL.path, withDestinationPath: "/usr/bin/true")

        #expect(try installer.uninstall())
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: installer.usageURL.path) == "/usr/bin/true")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: installer.linkURL.path)) == nil)
    }

    @Test("Instalação padrão não ocupa o nome genérico usage")
    func defaultInstallationDoesNotCreateAlias() throws {
        let directory = try TemporaryDirectory()
        let paths = Paths.resolve(environment: ["AGY_AGENT_HOME": directory.url.path], homeDirectory: directory.url)
        let installer = Installer(paths: paths, homeDirectory: directory.url)
        let executable = directory.url.appending(path: "agy-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        _ = try installer.install(executable: executable, environment: [:])
        #expect(!FileManager.default.fileExists(atPath: installer.usageURL.path))
    }

    @Test("Instalação padrão preserva comando usage alheio")
    func defaultInstallationPreservesForeignAlias() throws {
        let directory = try TemporaryDirectory()
        let paths = Paths.resolve(environment: ["AGY_AGENT_HOME": directory.url.path], homeDirectory: directory.url)
        let installer = Installer(paths: paths, homeDirectory: directory.url)
        try FileManager.default.createDirectory(at: installer.linkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: installer.usageURL.path, withDestinationPath: "/usr/bin/true")
        let executable = directory.url.appending(path: "agy-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        _ = try installer.install(executable: executable, environment: [:])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: installer.usageURL.path) == "/usr/bin/true")
    }
}
