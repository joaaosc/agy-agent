import Foundation

/// Envelope JSON emitido pelo evento final de `agy --output-format stream-json`.
///
/// Formato observado em agy 1.2.x:
/// ```json
/// {"conversation_id":"…","status":"SUCCESS","response":"OK\n",
///  "duration_seconds":1.93,"num_turns":1,
///  "usage":{"input_tokens":24809,"output_tokens":1,"thinking_tokens":0,
///           "cache_read_tokens":0,"total_tokens":24810}}
/// ```
/// Campos desconhecidos são ignorados; `status` aceita valores não previstos
/// para que uma versão futura do agy não quebre a decodificação.
public struct AgyEnvelope: Sendable, Codable, Equatable {
    public enum Status: Sendable, Equatable {
        case success
        case other(String)

        public var isSuccess: Bool { self == .success }

        public var rawValue: String {
            switch self {
            case .success: "SUCCESS"
            case .other(let value): value
            }
        }

        public init(rawValue: String) {
            self = rawValue.uppercased() == "SUCCESS" ? .success : .other(rawValue)
        }
    }

    public struct Usage: Sendable, Codable, Equatable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var thinkingTokens: Int
        public var cacheReadTokens: Int
        public var totalTokens: Int

        public init(
            inputTokens: Int = 0,
            outputTokens: Int = 0,
            thinkingTokens: Int = 0,
            cacheReadTokens: Int = 0,
            totalTokens: Int = 0
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.thinkingTokens = thinkingTokens
            self.cacheReadTokens = cacheReadTokens
            self.totalTokens = totalTokens
        }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case thinkingTokens = "thinking_tokens"
            case cacheReadTokens = "cache_read_tokens"
            case totalTokens = "total_tokens"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
            outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
            thinkingTokens = try container.decodeIfPresent(Int.self, forKey: .thinkingTokens) ?? 0
            cacheReadTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
            totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        }
    }

    public var conversationID: String?
    public var status: Status
    public var response: String
    public var durationSeconds: Double
    public var numTurns: Int
    public var usage: Usage

    public init(
        conversationID: String? = nil,
        status: Status = .success,
        response: String = "",
        durationSeconds: Double = 0,
        numTurns: Int = 0,
        usage: Usage = Usage()
    ) {
        self.conversationID = conversationID
        self.status = status
        self.response = response
        self.durationSeconds = durationSeconds
        self.numTurns = numTurns
        self.usage = usage
    }

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case status
        case response
        case durationSeconds = "duration_seconds"
        case numTurns = "num_turns"
        case usage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try container.decodeIfPresent(String.self, forKey: .conversationID)
        status = Status(rawValue: try container.decodeIfPresent(String.self, forKey: .status) ?? "SUCCESS")
        response = try container.decodeIfPresent(String.self, forKey: .response) ?? ""
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        numTurns = try container.decodeIfPresent(Int.self, forKey: .numTurns) ?? 0
        usage = try container.decodeIfPresent(Usage.self, forKey: .usage) ?? Usage()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(conversationID, forKey: .conversationID)
        try container.encode(status.rawValue, forKey: .status)
        try container.encode(response, forKey: .response)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(numTurns, forKey: .numTurns)
        try container.encode(usage, forKey: .usage)
    }

    /// `agy` pode emitir texto antes do JSON (avisos, progresso). O envelope é
    /// o último objeto JSON completo da saída.
    public static func decode(fromCombinedOutput output: String) throws -> AgyEnvelope {
        let decoder = JSONDecoder()
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
                  let data = trimmed.data(using: .utf8) else { continue }
            if let envelope = try? decoder.decode(AgyEnvelope.self, from: data) {
                return envelope
            }
        }
        throw AgyAgentError.malformedEnvelope(output)
    }

    /// No formato stream-json, o envelope fica em `result` no último evento
    /// cujo tipo é `result`; mensagens intermediárias são ignoradas.
    public static func decode(fromStreamOutput output: String) throws -> AgyEnvelope {
        let decoder = JSONDecoder()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["event"] as? String == "result",
                  let result = object["result"] as? [String: Any],
                  let resultData = try? JSONSerialization.data(withJSONObject: result),
                  let envelope = try? decoder.decode(AgyEnvelope.self, from: resultData) else { continue }
            return envelope
        }
        throw AgyAgentError.malformedEnvelope(output)
    }
}
