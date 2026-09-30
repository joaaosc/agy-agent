import Foundation

/// Workspace da chamada: o repositório sobre o qual o agy vai raciocinar.
///
/// O agy-agent não pertence ao projeto; ele apenas o anexa. Usar `pwd` cru é
/// insuficiente: uma chamada feita de `Repo/Sources/Foo` deve enxergar a raiz
/// do repositório, não o subdiretório. A resolução sobe até encontrar um
/// marcador de raiz e só então cai de volta para o diretório corrente.
public struct Workspace: Sendable, Equatable {
    /// Marcadores de raiz, em ordem de precedência.
    public static let rootMarkers = [".git", ".jj", "Package.swift", "AGENTS.md", "CLAUDE.md"]

    public let root: URL
    /// `true` quando a raiz veio de um marcador; `false` quando é apenas o cwd.
    public let isRepository: Bool

    public init(root: URL, isRepository: Bool) {
        self.root = DirectoryURL.normalized(root)
        self.isRepository = isRepository
    }

    /// Caminho canônico da raiz, usado em `--add-dir` e na chave de cache.
    public var rootPath: String { root.path(percentEncoded: false) }

    public func isHomeDirectory(_ homeDirectory: URL) -> Bool {
        root.resolvingSymlinksInPath().path(percentEncoded: false)
            == DirectoryURL.normalized(homeDirectory).resolvingSymlinksInPath().path(percentEncoded: false)
    }

    public func isUnsafeBroadDirectory(homeDirectory: URL) -> Bool {
        root.resolvingSymlinksInPath().path(percentEncoded: false) == "/"
            || isHomeDirectory(homeDirectory)
    }

    /// Resolve a raiz subindo a partir de `startingAt`.
    ///
    /// `exists` é injetado para manter a lógica testável sem tocar no disco.
    /// A subida para no diretório home ou em `/`, o que vier primeiro: um
    /// marcador solto acima do home anexaria a home inteira ao contexto.
    public static func resolve(
        startingAt startDirectory: URL,
        homeDirectory: URL,
        exists: (URL) -> Bool
    ) -> Workspace {
        let start = DirectoryURL.normalized(startDirectory)
        let homePath = DirectoryURL.path(homeDirectory)
        var current = start

        while true {
            // A home nunca pode virar workspace implícito. Arquivos globais
            // como ~/AGENTS.md e ~/.git não devem autorizar anexar todo o
            // diretório pessoal ao executor externo.
            if current.path(percentEncoded: false) == homePath { break }
            for marker in rootMarkers where exists(current.appending(path: marker)) {
                return Workspace(root: current, isRepository: true)
            }
            let parent = DirectoryURL.normalized(current.deletingLastPathComponent())
            if parent.path(percentEncoded: false) == current.path(percentEncoded: false) { break }
            current = parent
        }

        return Workspace(root: start, isRepository: false)
    }
}

/// Restringe anexos recebidos pelo MCP à árvore onde o servidor foi iniciado.
/// A resolução de symlinks acontece antes da comparação para impedir escapes.
public enum MCPAttachmentPolicy {
    public static func resolve(_ path: String, within root: URL) -> URL? {
        guard !path.isEmpty, !path.utf8.contains(0) else { return nil }
        let normalizedRoot = DirectoryURL.normalized(root).resolvingSymlinksInPath()
        guard normalizedRoot.path(percentEncoded: false) != "/" else { return nil }
        let unresolved = path.hasPrefix("/")
            ? URL(filePath: path, directoryHint: .notDirectory)
            : normalizedRoot.appending(path: path, directoryHint: .notDirectory)
        let candidate = unresolved.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = normalizedRoot.path(percentEncoded: false)
        let candidatePath = candidate.path(percentEncoded: false)
        guard candidatePath.hasPrefix(rootPath + "/") else { return nil }
        guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return candidate
    }
}
