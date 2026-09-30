import Foundation

/// Carga dos prompts de sistema.
///
/// Os prompts vivem em `~/.config/agy-agent/prompts/<modo>.md`, editáveis à
/// mão. O pacote traz uma cópia de referência em `Resources/Prompts`, usada
/// apenas para semear o diretório na primeira execução — por cópia, nunca por
/// symlink: editar o prompt local não pode alterar o repositório.
public struct PromptLibrary: Sendable {
    private let directory: URL
    private let seeds: [Mode: String]
    private let readFile: @Sendable (URL) -> String?

    public init(
        directory: URL,
        seeds: [Mode: String] = PromptLibrary.bundledSeeds,
        readFile: @escaping @Sendable (URL) -> String? = { url in
            FileManager.default.contents(atPath: url.path(percentEncoded: false)).map {
                String(decoding: $0, as: UTF8.self)
            }
        }
    ) {
        self.directory = DirectoryURL.normalized(directory)
        self.seeds = seeds
        self.readFile = readFile
    }

    public func url(for mode: Mode) -> URL {
        directory.appending(path: mode.promptFileName)
    }

    /// Prompt do modo.
    ///
    /// Se o arquivo existir, ele vence — o usuário editou de propósito. Se não
    /// existir, cai para a cópia embutida em vez de falhar: a ferramenta tem
    /// que funcionar numa máquina recém-configurada.
    public func prompt(for mode: Mode) throws -> String {
        if let text = readFile(url(for: mode)), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        guard let seed = seeds[mode] else {
            throw AgyAgentError.missingPrompt(mode, url(for: mode))
        }
        return seed
    }

    /// De onde veio o prompt, para diagnóstico.
    public func origin(for mode: Mode) -> String {
        if let text = readFile(url(for: mode)), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return url(for: mode).path(percentEncoded: false)
        }
        return "embutido"
    }

    /// Escreve no disco os prompts que ainda não existem.
    ///
    /// Nunca sobrescreve: um prompt já editado pelo usuário é a fonte da
    /// verdade. Devolve os modos efetivamente semeados.
    @discardableResult
    public func seedMissing() throws -> [Mode] {
        var written: [Mode] = []
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw AgyAgentError.storeFailed("criar \(directory.path(percentEncoded: false)): \(error.localizedDescription)")
        }

        for mode in Mode.allCases {
            let destination = url(for: mode)
            guard readFile(destination) == nil, let seed = seeds[mode] else { continue }
            do {
                try Data(seed.utf8).write(to: destination, options: .withoutOverwriting)
                written.append(mode)
            } catch {
                // Outra sessão pode ter semeado no mesmo instante; isso não é
                // falha, é a corrida esperada.
                continue
            }
        }
        return written
    }
}


extension PromptLibrary {
    /// Prompts de referência embarcados a partir de `Resources/Prompts`.
    ///
    /// Se um arquivo faltar no bundle, o modo simplesmente não é semeado e
    /// `prompt(for:)` falha com `missingPrompt` — que é o comportamento
    /// correto: melhor recusar do que delegar com prompt vazio.
    public static let bundledSeeds: [Mode: String] = {
        var seeds: [Mode: String] = [:]
        for mode in Mode.allCases {
            guard let url = Bundle.module.url(
                forResource: mode.rawValue,
                withExtension: "md",
                subdirectory: "Prompts"
            ), let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else { continue }
            seeds[mode] = String(decoding: data, as: UTF8.self)
        }
        return seeds
    }()
}
