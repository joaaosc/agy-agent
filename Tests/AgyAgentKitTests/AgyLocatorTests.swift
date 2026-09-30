import Testing
import Foundation
@testable import AgyAgentKit

@Suite("Localização do executável agy")
struct AgyLocatorTests {
    let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)

    func locator(_ executables: Set<String>) -> AgyLocator {
        AgyLocator { url in executables.contains(url.path(percentEncoded: false)) }
    }

    @Test("Caminho explícito tem precedência sobre tudo")
    func explicitWins() throws {
        let source = try locator(["/opt/agy", "/usr/bin/agy"]).locate(
            explicitPath: "/opt/agy",
            environment: ["AGY_BIN": "/usr/bin/agy", "PATH": "/usr/bin"],
            homeDirectory: home
        )
        #expect(source == .explicit(URL(filePath: "/opt/agy", directoryHint: .notDirectory)))
    }

    @Test("Caminho explícito inválido falha em vez de cair para o PATH")
    func explicitDoesNotFallBack() {
        #expect(throws: AgyAgentError.self) {
            try locator(["/usr/bin/agy"]).locate(
                explicitPath: "/opt/inexistente",
                environment: ["PATH": "/usr/bin"],
                homeDirectory: home
            )
        }
    }

    @Test("AGY_BIN vem antes do PATH")
    func environmentBeforePath() throws {
        let source = try locator(["/custom/agy", "/usr/bin/agy"]).locate(
            environment: ["AGY_BIN": "/custom/agy", "PATH": "/usr/bin"],
            homeDirectory: home
        )
        #expect(source.url.path(percentEncoded: false) == "/custom/agy")
    }

    @Test("Varredura do PATH respeita a ordem das entradas")
    func pathOrder() throws {
        let source = try locator(["/a/agy", "/b/agy"]).locate(
            environment: ["PATH": "/b:/a"],
            homeDirectory: home
        )
        #expect(source == .path(URL(filePath: "/b/agy", directoryHint: .notDirectory)))
    }

    @Test("Til nas entradas do PATH é expandido")
    func tildeInPath() throws {
        let source = try locator(["/Users/tester/bin/agy"]).locate(
            environment: ["PATH": "~/bin"],
            homeDirectory: home
        )
        #expect(source.url.path(percentEncoded: false) == "/Users/tester/bin/agy")
    }

    @Test("Sem PATH útil, cai para ~/.local/bin/agy")
    func fallback() throws {
        let source = try locator(["/Users/tester/.local/bin/agy"]).locate(
            environment: ["PATH": "/nada"],
            homeDirectory: home
        )
        #expect(source == .fallback(URL(filePath: "/Users/tester/.local/bin/agy", directoryHint: .notDirectory)))
    }

    @Test("Nenhum candidato executável produz erro listando onde procurou")
    func notFound() {
        #expect(throws: AgyAgentError.self) {
            try locator([]).locate(environment: ["PATH": "/x:/y"], homeDirectory: home)
        }
    }
}
