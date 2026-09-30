import Foundation

/// Normalização de URLs de diretório.
///
/// `URL(filePath:directoryHint:.isDirectory)` produz caminhos terminados em
/// `/`, enquanto `appending(path:)` normalmente não. A diferença é invisível
/// no uso comum, mas contamina comparações de igualdade e, pior, entra no
/// digest da chave de cache: `/Repo` e `/Repo/` gerariam entradas distintas
/// para o mesmo workspace. Todo caminho de diretório cruza esta função.
public enum DirectoryURL {
    /// Remove barra final e resolve `.`/`..`, preservando a raiz `/`.
    public static func normalized(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        let path = standardized.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return standardized }
        return URL(filePath: String(path.dropLast()), directoryHint: .notDirectory)
    }

    /// Caminho canônico de um diretório, sem barra final.
    public static func path(_ url: URL) -> String {
        normalized(url).path(percentEncoded: false)
    }
}
