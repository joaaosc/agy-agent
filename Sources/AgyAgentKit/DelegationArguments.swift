import Foundation

/// Análise dos argumentos de um subcomando de delegação.
///
/// Separado do `main.swift` para poder crescer sem virar um switch gigante, e
/// porque a análise é pura: dá para raciocinar sobre ela sem executar nada.
public struct DelegationArguments {
    public static let maximumAttachmentBytes = 20 * 1024 * 1024
    public var mode: Mode
    public var question: String
    public var model: String?
    public var timeoutSeconds: Int?
    public var responseBudget: Int?
    public var attachmentPath: String?
    public var conversationID: String?
    public var cachePolicy: DelegationService.CachePolicy = .use
    public var json = false
    public var quiet = false

    public enum ParseError: Error, CustomStringConvertible {
        case unknownFlag(String)
        case missingValue(String)
        case invalidValue(flag: String, value: String)
        case missingQuestion(Mode)

        public var description: String {
            switch self {
            case .unknownFlag(let flag): "opção desconhecida: \(flag)"
            case .missingValue(let flag): "\(flag) exige um valor"
            case .invalidValue(let flag, let value): "\(flag): valor inválido `\(value)`"
            case .missingQuestion(let mode): "uso: agy-agent \(mode.rawValue) [opções] <pergunta>"
            }
        }
    }

    /// `readStandardInput` é injetado para que a análise possa ser testada
    /// sem um terminal.
    public static func parse(
        mode: Mode,
        arguments: [String],
        readStandardInput: () -> String?
    ) throws -> DelegationArguments {
        var parsed = DelegationArguments(mode: mode, question: "")
        var words: [String] = []
        var index = 0

        func value(for flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ParseError.missingValue(flag) }
            return arguments[index]
        }

        func positive(_ flag: String) throws -> Int {
            let raw = try value(for: flag)
            guard let number = Int(raw), number > 0 else {
                throw ParseError.invalidValue(flag: flag, value: raw)
            }
            return number
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--model":
                let model = try value(for: argument)
                guard DelegationRequest.isValidModel(model) else {
                    throw ParseError.invalidValue(flag: argument, value: model)
                }
                parsed.model = model
            case "--timeout": parsed.timeoutSeconds = try positive(argument)
            case "--budget":
                let budget = try positive(argument)
                guard budget <= DelegationRequest.maximumResponseBudget else {
                    throw ParseError.invalidValue(flag: argument, value: String(budget))
                }
                parsed.responseBudget = budget
            case "--file": parsed.attachmentPath = try value(for: argument)
            case "--conversation":
                let id = try value(for: argument)
                guard DelegationRequest.isValidConversationID(id) else {
                    throw ParseError.invalidValue(flag: argument, value: id)
                }
                parsed.conversationID = id
                // Acompanhamento depende do histórico da conversa: a mesma
                // pergunta em outra conversa tem outra resposta. Não usa cache.
                parsed.cachePolicy = .bypass
            case "--refresh": if parsed.conversationID == nil { parsed.cachePolicy = .refresh }
            case "--no-cache": parsed.cachePolicy = .bypass
            case "--json": parsed.json = true
            case "--quiet", "-q": parsed.quiet = true
            case "--":
                // Tudo depois de `--` é pergunta, mesmo começando com traço.
                words.append(contentsOf: arguments[(index + 1)...])
                index = arguments.count
            default:
                guard !argument.hasPrefix("--") else { throw ParseError.unknownFlag(argument) }
                words.append(argument)
            }
            index += 1
        }

        parsed.question = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if parsed.question.isEmpty {
            // Sem pergunta nos argumentos, lê de stdin: é como um pipe entrega
            // um diff ou um log.
            parsed.question = (readStandardInput() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !parsed.question.isEmpty else { throw ParseError.missingQuestion(mode) }
        return parsed
    }

    /// Anexo por caminho: o conteúdo nunca é colado no comando.
    ///
    /// É a diferença entre economizar e desperdiçar contexto — se o chamador
    /// precisasse colar o arquivo, ele já teria pago por aquele texto.
    public func attachment() throws -> DelegationAttachment? {
        guard let attachmentPath else { return nil }
        let url = URL(filePath: attachmentPath, directoryHint: .notDirectory)
        let absolute = url.path(percentEncoded: false).hasPrefix("/")
            ? url
            : URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
                .appending(path: attachmentPath)
        guard let size = try? absolute.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw AgyAgentError.storeFailed("arquivo não encontrado: \(absolute.path(percentEncoded: false))")
        }
        guard size <= Self.maximumAttachmentBytes else {
            throw AgyAgentError.storeFailed("arquivo excede o limite de \(Self.maximumAttachmentBytes) bytes")
        }
        guard let data = try? Data(contentsOf: absolute, options: .mappedIfSafe) else {
            throw AgyAgentError.storeFailed("arquivo ilegível: \(absolute.path(percentEncoded: false))")
        }
        guard data.count <= Self.maximumAttachmentBytes else {
            throw AgyAgentError.storeFailed("arquivo cresceu além do limite durante a leitura")
        }
        return .file(
            path: absolute.path(percentEncoded: false),
            contentDigest: Digest.sha256(data)
        )
    }
}
