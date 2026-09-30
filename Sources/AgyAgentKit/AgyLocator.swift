import Foundation

/// Localização do executável `agy`.
///
/// A resolução nunca passa por shell. A função `agy()` definida no ambiente do
/// usuário injeta `--model gemini-3.5-flash`, modelo que não consta em
/// `agy models`; invocar por shell herdaria esse argumento. Chamar o binário
/// diretamente também dispensa qualquer escape de caminho com espaço.
public struct AgyLocator: Sendable {
    /// Ordem de precedência da busca.
    public enum Source: Sendable, Equatable {
        case explicit(URL)
        case environment(URL)
        case path(URL)
        case fallback(URL)

        public var url: URL {
            switch self {
            case .explicit(let url), .environment(let url), .path(let url), .fallback(let url): url
            }
        }
    }

    public static let executableName = "agy"

    private let isExecutable: @Sendable (URL) -> Bool

    public init(isExecutable: @escaping @Sendable (URL) -> Bool) {
        self.isExecutable = isExecutable
    }

    public init() {
        self.init { url in
            FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false))
        }
    }

    /// Resolve o executável ou explica onde procurou.
    public func locate(
        explicitPath: String? = nil,
        environment: [String: String],
        homeDirectory: URL
    ) throws -> Source {
        var attempted: [String] = []

        if let explicitPath, !explicitPath.isEmpty {
            let url = Self.fileURL(explicitPath, homeDirectory: homeDirectory)
            // Um caminho explícito é uma afirmação do chamador: se não serve,
            // cair para o PATH esconderia o erro de configuração.
            guard isExecutable(url) else {
                throw AgyAgentError.agyNotFound(url.path(percentEncoded: false))
            }
            return .explicit(url)
        }

        if let value = environment["AGY_BIN"], !value.isEmpty {
            let url = Self.fileURL(value, homeDirectory: homeDirectory)
            guard isExecutable(url) else {
                throw AgyAgentError.agyNotFound(url.path(percentEncoded: false))
            }
            return .environment(url)
        }

        for directory in (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            let base = Self.fileURL(String(directory), homeDirectory: homeDirectory)
            let candidate = base.appending(path: Self.executableName)
            attempted.append(candidate.path(percentEncoded: false))
            if isExecutable(candidate) { return .path(candidate) }
        }

        let fallback = homeDirectory.appending(path: ".local/bin/\(Self.executableName)")
        attempted.append(fallback.path(percentEncoded: false))
        if isExecutable(fallback) { return .fallback(fallback) }

        throw AgyAgentError.agyNotFound(attempted.isEmpty ? Self.executableName : attempted.joined(separator: ", "))
    }

    static func fileURL(_ value: String, homeDirectory: URL) -> URL {
        if value == "~" { return DirectoryURL.normalized(homeDirectory) }
        if value.hasPrefix("~/") {
            return DirectoryURL.normalized(homeDirectory.appending(path: String(value.dropFirst(2))))
        }
        return DirectoryURL.normalized(URL(filePath: value, directoryHint: .inferFromPath))
    }
}
