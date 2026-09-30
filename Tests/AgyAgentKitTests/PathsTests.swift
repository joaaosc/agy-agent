import Testing
import Foundation
@testable import AgyAgentKit

@Suite("Resolução de caminhos")
struct PathsTests {
    let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)

    @Test("Padrão macOS separa config XDG de dados da Library")
    func defaultLayout() {
        let paths = Paths.resolve(environment: [:], homeDirectory: home)
        #expect(paths.configDirectory.path(percentEncoded: false) == "/Users/tester/.config/agy-agent")
        #expect(paths.promptsDirectory.path(percentEncoded: false) == "/Users/tester/.config/agy-agent/prompts")
        #expect(paths.dataDirectory.path(percentEncoded: false) == "/Users/tester/Library/Application Support/agy-agent")
        #expect(paths.cacheDirectory.path(percentEncoded: false) == "/Users/tester/Library/Caches/agy-agent")
        #expect(paths.logFile.path(percentEncoded: false) == "/Users/tester/Library/Logs/agy-agent/agy-agent.log")
    }

    @Test("Conhecimento durável e cache descartável ficam em arquivos distintos")
    func knowledgeAndCacheAreSeparate() {
        let paths = Paths.resolve(environment: [:], homeDirectory: home)
        #expect(paths.knowledgeDatabase != paths.cacheDatabase)
        #expect(paths.knowledgeDatabase.path(percentEncoded: false).contains("Application Support"))
        #expect(paths.cacheDatabase.path(percentEncoded: false).contains("Caches"))
    }

    @Test("XDG_CONFIG_HOME redireciona apenas a configuração")
    func xdgOverride() {
        let paths = Paths.resolve(environment: ["XDG_CONFIG_HOME": "/etc/xdg"], homeDirectory: home)
        #expect(paths.configDirectory.path(percentEncoded: false) == "/etc/xdg/agy-agent")
        #expect(paths.dataDirectory.path(percentEncoded: false).hasPrefix("/Users/tester/Library"))
    }

    @Test("AGY_AGENT_HOME redireciona todas as raízes")
    func fullOverride() {
        let paths = Paths.resolve(environment: ["AGY_AGENT_HOME": "/tmp/sandbox"], homeDirectory: home)
        for url in [paths.configDirectory, paths.dataDirectory, paths.cacheDirectory, paths.logDirectory] {
            #expect(url.path(percentEncoded: false).hasPrefix("/tmp/sandbox"))
        }
        #expect(paths.stateDirectory.path(percentEncoded: false) == "/tmp/sandbox/data/state")
    }

    @Test("Caminho relativo em variável de ambiente é ignorado")
    func relativeOverrideIsIgnored() {
        let paths = Paths.resolve(environment: ["AGY_AGENT_HOME": "relativo/nao/vale"], homeDirectory: home)
        #expect(paths.configDirectory.path(percentEncoded: false) == "/Users/tester/.config/agy-agent")
    }

    @Test("Til é expandido para a home informada")
    func tildeExpansion() {
        #expect(Paths.absoluteURL("~/x", relativeTo: home)?.path(percentEncoded: false) == "/Users/tester/x")
        #expect(Paths.absoluteURL("~", relativeTo: home)?.path(percentEncoded: false) == "/Users/tester")
        #expect(Paths.absoluteURL("", relativeTo: home) == nil)
        #expect(Paths.absoluteURL(nil, relativeTo: home) == nil)
    }

    @Test("Diretórios graváveis não incluem a configuração")
    func writableDirectoriesExcludeConfig() {
        let paths = Paths.resolve(environment: [:], homeDirectory: home)
        #expect(!paths.writableDirectories.contains(paths.configDirectory))
        #expect(paths.writableDirectories.contains(paths.cacheDirectory))
    }
}
