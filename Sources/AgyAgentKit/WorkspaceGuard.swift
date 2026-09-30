import Foundation

/// Detecção de alteração do workspace durante uma delegação.
///
/// Prevenção não está disponível: em `agy --print` nenhuma combinação de
/// flags testada impediu o agente de escrever nos diretórios passados em
/// `--add-dir`. `--mode plan` é ignorado junto com `--disable-slash-commands`
/// e, mesmo sozinho, não bloqueou a escrita; `--sandbox` concede leitura e
/// escrita ao workspace por definição. O que resta é detectar e avisar.
///
/// Em repositório Git a comparação usa `git status --porcelain` mais o
/// `HEAD`, que cobre arquivo novo, modificado, apagado e commit criado. Fora
/// de Git há uma varredura de diretório com caminho, tamanho e data de
/// modificação — menos precisa, mas melhor do que não verificar nada.
public struct WorkspaceGuard: Sendable {
    /// Teto da varredura sem Git.
    ///
    /// Uma árvore muito grande tornaria a verificação mais cara que a própria
    /// delegação. Ao estourar o teto, a verificação é declarada indisponível
    /// em vez de entregar resultado parcial, que daria falsa segurança.
    public static let fileScanLimit = 20_000

    /// Diretórios pulados na varredura sem Git: conteúdo derivado, que muda
    /// sozinho e produziria alarme falso.
    public static let skippedDirectories: Set<String> = [
        ".git", ".jj", ".build", ".swiftpm", "DerivedData", "node_modules",
        ".venv", "venv", "__pycache__", ".next", "dist", "target", ".cache",
    ]

    public struct Snapshot: Sendable, Equatable {
        public enum Source: Sendable, Equatable {
            case git
            case fileScan
            case unavailable
        }

        public let digest: String?
        public let source: Source

        public var isAvailable: Bool { digest != nil }

        public init(digest: String?, source: Source) {
            self.digest = digest
            self.source = source
        }

        public static let unavailable = Snapshot(digest: nil, source: .unavailable)
    }

    public enum Verdict: Sendable, Equatable {
        case unchanged
        case changed(Snapshot.Source)
        /// Não foi possível verificar (sem Git e árvore grande demais, ou
        /// diretório ilegível).
        case unavailable

        public var warning: String? {
            switch self {
            case .unchanged:
                nil
            case .changed(let source):
                "o workspace foi alterado durante a chamada (detectado por \(source == .git ? "git status" : "varredura de arquivos")) — revise antes de confiar no resultado"
            case .unavailable:
                nil
            }
        }
    }

    private let processRunner: any ProcessRunning
    private let gitExecutable: URL
    private let fileSystem: any WorkspaceFileSystem

    public init(
        processRunner: any ProcessRunning = SubprocessRunner(),
        gitExecutable: URL = URL(filePath: "/usr/bin/git", directoryHint: .notDirectory),
        fileSystem: any WorkspaceFileSystem = DefaultWorkspaceFileSystem()
    ) {
        self.processRunner = processRunner
        self.gitExecutable = gitExecutable
        self.fileSystem = fileSystem
    }

    public func snapshot(of workspace: Workspace) -> Snapshot {
        if let status = git(["status", "--porcelain"], in: workspace.root) {
            let head = git(["rev-parse", "HEAD"], in: workspace.root) ?? "sem-head"
            return Snapshot(digest: Digest.sha256("\(head)\u{1F}\(status)"), source: .git)
        }
        guard let fingerprint = fileSystem.fingerprint(
            of: workspace.root,
            skipping: Self.skippedDirectories,
            limit: Self.fileScanLimit
        ) else {
            return .unavailable
        }
        return Snapshot(digest: fingerprint, source: .fileScan)
    }

    public func verdict(before: Snapshot, after: Snapshot) -> Verdict {
        guard let beforeDigest = before.digest, let afterDigest = after.digest else { return .unavailable }
        // Fontes diferentes não são comparáveis: um repositório que deixou de
        // ser legível pelo git no meio da chamada não é prova de alteração.
        guard before.source == after.source else { return .unavailable }
        return beforeDigest == afterDigest ? .unchanged : .changed(before.source)
    }

    /// Há trabalho não commitado na árvore?
    ///
    /// Avisar **antes** da chamada importa mais que avisar depois: com a
    /// árvore limpa, qualquer escrita indevida é desfeita com um comando.
    public func hasUncommittedWork(in workspace: Workspace) -> Bool {
        guard let status = git(["status", "--porcelain"], in: workspace.root) else { return false }
        return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func git(_ arguments: [String], in directory: URL) -> String? {
        let plan = ProcessPlan(
            executable: gitExecutable,
            arguments: arguments,
            workingDirectory: directory,
            // `git` sem ambiente herdado evita que configuração de pager ou
            // de cor do usuário altere a saída comparada.
            environment: ["PATH": "/usr/bin:/bin", "GIT_OPTIONAL_LOCKS": "0", "NO_COLOR": "1"],
            timeout: .seconds(20)
        )
        guard let result = try? processRunner.run(plan), result.exitCode == 0 else { return nil }
        return result.standardOutput
    }
}

/// Varredura de árvore, isolada para poder ser substituída em teste.
public protocol WorkspaceFileSystem: Sendable {
    /// Digest de caminho, tamanho e data de modificação de cada arquivo.
    /// `nil` quando o diretório é ilegível ou excede `limit` arquivos.
    func fingerprint(of root: URL, skipping: Set<String>, limit: Int) -> String?
}

public struct DefaultWorkspaceFileSystem: WorkspaceFileSystem {
    public init() {}

    public func fingerprint(of root: URL, skipping: Set<String>, limit: Int) -> String? {
        // Um enumerador sobre caminho inexistente pode render zero entradas,
        // o que produziria um digest válido de árvore vazia e diria
        // "inalterado" sobre um diretório que nem existe.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .nameKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var entries: [String] = []
        entries.reserveCapacity(1024)

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                if entries.count >= limit { return nil }
                let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false))) ?? "<ilegível>"
                entries.append("link\u{1F}\(url.path(percentEncoded: false))\u{1F}\(destination)")
                continue
            }
            if values.isDirectory == true {
                if skipping.contains(values.name ?? "") { enumerator.skipDescendants() }
                continue
            }
            if entries.count >= limit { return nil }
            let size = values.fileSize ?? 0
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            entries.append("\(url.path(percentEncoded: false))\u{1F}\(size)\u{1F}\(modified)")
        }

        // A ordem do enumerador não é garantida; sem ordenar, duas varreduras
        // da mesma árvore poderiam gerar digests diferentes.
        return Digest.sha256(entries.sorted().joined(separator: "\u{1E}"))
    }
}
