import Testing
import Foundation
@testable import AgyAgentKit

@Suite("Envelope JSON do agy")
struct AgyEnvelopeTests {
    /// Amostra legada capturada de `agy 1.2.7 --output-format json`.
    static let sample = #"""
    {"conversation_id":"3f7b40f1-89f5-45d6-bb68-c2f9a5570935","status":"SUCCESS","response":"OK\n","duration_seconds":1.935781,"num_turns":1,"usage":{"input_tokens":24809,"output_tokens":1,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":24810}}
    """#

    @Test("Decodifica a amostra real")
    func decodesSample() throws {
        let envelope = try AgyEnvelope.decode(fromCombinedOutput: Self.sample)
        #expect(envelope.conversationID == "3f7b40f1-89f5-45d6-bb68-c2f9a5570935")
        #expect(envelope.status == .success)
        #expect(envelope.response == "OK\n")
        #expect(envelope.numTurns == 1)
        #expect(envelope.usage.inputTokens == 24809)
        #expect(envelope.usage.totalTokens == 24810)
    }

    @Test("Ignora ruído antes do envelope")
    func ignoresLeadingNoise() throws {
        let output = "Fetching available models...\nwarning: algo\n" + Self.sample
        let envelope = try AgyEnvelope.decode(fromCombinedOutput: output)
        #expect(envelope.status == .success)
    }

    @Test("Status desconhecido não quebra a decodificação")
    func unknownStatus() throws {
        let output = #"{"status":"CANCELLED","response":""}"#
        let envelope = try AgyEnvelope.decode(fromCombinedOutput: output)
        #expect(envelope.status == .other("CANCELLED"))
        #expect(!envelope.status.isSuccess)
    }

    @Test("Campos ausentes recebem padrões")
    func missingFields() throws {
        let envelope = try AgyEnvelope.decode(fromCombinedOutput: #"{"response":"texto"}"#)
        #expect(envelope.status == .success)
        #expect(envelope.conversationID == nil)
        #expect(envelope.durationSeconds == 0)
        #expect(envelope.usage.totalTokens == 0)
    }

    @Test("Saída sem JSON produz erro explícito")
    func malformed() {
        #expect(throws: AgyAgentError.self) {
            try AgyEnvelope.decode(fromCombinedOutput: "erro: autenticação expirada")
        }
    }

    @Test("Roundtrip Codable preserva o conteúdo")
    func roundtrip() throws {
        let original = try AgyEnvelope.decode(fromCombinedOutput: Self.sample)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(AgyEnvelope.self, from: data)
        #expect(restored == original)
    }
}
