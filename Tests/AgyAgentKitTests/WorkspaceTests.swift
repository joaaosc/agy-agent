import Testing
import Foundation
@testable import AgyAgentKit

@Suite("Resolução de workspace")
struct WorkspaceTests {
    let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)

    func resolver(_ existing: Set<String>) -> (URL) -> Bool {
        { existing.contains($0.path(percentEncoded: false)) }
    }

    @Test("Sobe até a raiz marcada por .git")
    func findsGitRoot() {
        let workspace = Workspace.resolve(
            startingAt: URL(filePath: "/Users/tester/Repo/Sources/Foo", directoryHint: .isDirectory),
            homeDirectory: home,
            exists: resolver(["/Users/tester/Repo/.git"])
        )
        #expect(workspace.root.path(percentEncoded: false) == "/Users/tester/Repo")
        #expect(workspace.isRepository)
    }

    @Test("Sem marcador, cai para o diretório corrente")
    func fallsBackToCurrentDirectory() {
        let start = URL(filePath: "/Users/tester/avulso", directoryHint: .isDirectory)
        let workspace = Workspace.resolve(startingAt: start, homeDirectory: home, exists: resolver([]))
        #expect(workspace.root.path(percentEncoded: false) == "/Users/tester/avulso")
        #expect(!workspace.isRepository)
    }

    @Test("A subida não ultrapassa a home")
    func stopsAtHome() {
        let workspace = Workspace.resolve(
            startingAt: URL(filePath: "/Users/tester/a/b", directoryHint: .isDirectory),
            homeDirectory: home,
            exists: resolver(["/Users/.git"])
        )
        #expect(!workspace.isRepository)
        #expect(workspace.root.path(percentEncoded: false) == "/Users/tester/a/b")
    }

    @Test("A home marcada nunca é anexada como workspace implícito")
    func homeItselfCannotBeRoot() {
        let workspace = Workspace.resolve(
            startingAt: home,
            homeDirectory: home,
            exists: resolver(["/Users/tester/.git"])
        )
        #expect(!workspace.isRepository)
        #expect(DirectoryURL.path(workspace.root) == DirectoryURL.path(home))
        #expect(workspace.isHomeDirectory(home))
        #expect(workspace.isUnsafeBroadDirectory(homeDirectory: home))
    }

    @Test("Package.swift também marca raiz")
    func swiftPackageMarker() {
        let workspace = Workspace.resolve(
            startingAt: URL(filePath: "/Users/tester/pkg/Sources", directoryHint: .isDirectory),
            homeDirectory: home,
            exists: resolver(["/Users/tester/pkg/Package.swift"])
        )
        #expect(workspace.root.path(percentEncoded: false) == "/Users/tester/pkg")
    }
}

@Suite("Normalização de diretórios")
struct DirectoryURLTests {
    @Test("Barra final é removida")
    func stripsTrailingSlash() {
        #expect(DirectoryURL.path(URL(filePath: "/a/b/", directoryHint: .isDirectory)) == "/a/b")
        #expect(DirectoryURL.path(URL(filePath: "/a/b", directoryHint: .notDirectory)) == "/a/b")
    }

    @Test("A raiz permanece /")
    func preservesRoot() {
        #expect(DirectoryURL.path(URL(filePath: "/", directoryHint: .isDirectory)) == "/")
    }

    @Test("Componentes relativos são resolvidos")
    func standardizes() {
        #expect(DirectoryURL.path(URL(filePath: "/a/b/../c/", directoryHint: .isDirectory)) == "/a/c")
    }

    @Test("Formas diferentes do mesmo diretório produzem a mesma chave de cache")
    func sameCacheKeyRegardlessOfForm() {
        let withSlash = Workspace(root: URL(filePath: "/Users/tester/Repo/", directoryHint: .isDirectory), isRepository: true)
        let withoutSlash = Workspace(root: URL(filePath: "/Users/tester/Repo", directoryHint: .isDirectory), isRepository: true)
        let a = Query(mode: .inspect, question: "q", model: "m", workspaceRoot: withSlash.rootPath, promptDigest: "p")
        let b = Query(mode: .inspect, question: "q", model: "m", workspaceRoot: withoutSlash.rootPath, promptDigest: "p")
        #expect(a.cacheKey == b.cacheKey)
    }
}

@Suite("Política de anexos MCP")
struct MCPAttachmentPolicyTests {
    @Test("Aceita arquivo interno e rejeita escape, diretório e symlink externo")
    func confinesAttachments() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(path: "input.txt")
        try Data("ok".utf8).write(to: file)
        #expect(MCPAttachmentPolicy.resolve("input.txt", within: directory.url) == file)
        #expect(MCPAttachmentPolicy.resolve("../outside.txt", within: directory.url) == nil)
        #expect(MCPAttachmentPolicy.resolve(".", within: directory.url) == nil)

        let outside = directory.url.deletingLastPathComponent().appending(path: "agy-agent-outside-\(UUID().uuidString)")
        try Data("private".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = directory.url.appending(path: "escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(MCPAttachmentPolicy.resolve("escape", within: directory.url) == nil)
        #expect(MCPAttachmentPolicy.resolve("/etc/hosts", within: URL(filePath: "/", directoryHint: .isDirectory)) == nil)
    }
}
