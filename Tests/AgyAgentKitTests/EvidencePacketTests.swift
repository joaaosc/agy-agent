import Testing
import Foundation
@testable import AgyAgentKit

@Suite("Chave de cache e pacotes de evidência")
struct EvidencePacketTests {
    func makeQuery(
        mode: Mode = .verify,
        question: String = "A API X existe no SDK do macOS 27?",
        model: String = "gemini-3.8-flash-medium",
        workspaceRoot: String? = nil,
        promptDigest: String = "prompt-v1",
        attachmentDigest: String? = nil
    ) -> Query {
        Query(
            mode: mode,
            question: question,
            model: model,
            workspaceRoot: workspaceRoot,
            promptDigest: promptDigest,
            attachmentDigest: attachmentDigest
        )
    }

    @Test("Perguntas equivalentes compartilham a chave")
    func normalizationCollapsesCosmeticDifferences() {
        let a = makeQuery(question: "  A API  X existe? ")
        let b = makeQuery(question: "a api x existe?")
        #expect(a.cacheKey == b.cacheKey)
    }

    @Test("Modo, modelo, workspace, prompt e anexo alteram a chave")
    func discriminatingFields() {
        let base = makeQuery()
        #expect(makeQuery(mode: .research).cacheKey != base.cacheKey)
        #expect(makeQuery(model: "gemini-3.1-pro-high").cacheKey != base.cacheKey)
        #expect(makeQuery(workspaceRoot: "/Users/tester/Repo").cacheKey != base.cacheKey)
        #expect(makeQuery(promptDigest: "prompt-v2").cacheKey != base.cacheKey)
        #expect(makeQuery(attachmentDigest: "diff-abc").cacheKey != base.cacheKey)
    }

    @Test("A chave é um digest hexadecimal de 64 caracteres")
    func keyShape() {
        let key = makeQuery().cacheKey
        #expect(key.count == 64)
        #expect(key.allSatisfy { $0.isHexDigit })
    }

    @Test("Separador evita colisão entre campos concatenados")
    func noFieldBoundaryCollision() {
        let a = makeQuery(promptDigest: "ab", attachmentDigest: "c")
        let b = makeQuery(promptDigest: "a", attachmentDigest: "bc")
        #expect(a.cacheKey != b.cacheKey)
    }

    @Test("Pacote construído a partir do envelope apara a resposta")
    func packetFromEnvelope() throws {
        let envelope = try AgyEnvelope.decode(fromCombinedOutput: AgyEnvelopeTests.sample)
        let query = makeQuery()
        let packet = EvidencePacket(query: query, envelope: envelope, agyVersion: "1.2.7")
        #expect(packet.response == "OK")
        #expect(packet.cacheKey == query.cacheKey)
        #expect(packet.conversationID == envelope.conversationID)
        #expect(packet.usage.totalTokens == 24810)
        #expect(packet.schemaVersion == EvidencePacket.schemaVersion)
    }

    @Test("Modos dependentes da web envelhecem")
    func freshnessForWebModes() {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let packet = EvidencePacket(cacheKey: "k", query: makeQuery(mode: .research), response: "r", createdAt: created)
        #expect(packet.isFresh(at: created.addingTimeInterval(60), maxAge: .seconds(3600)))
        #expect(!packet.isFresh(at: created.addingTimeInterval(7200), maxAge: .seconds(3600)))
    }

    @Test("Modos sem web não envelhecem pelo relógio")
    func freshnessForLocalModes() {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let packet = EvidencePacket(cacheKey: "k", query: makeQuery(mode: .summarize), response: "r", createdAt: created)
        #expect(packet.isFresh(at: created.addingTimeInterval(10_000_000), maxAge: .seconds(60)))
    }

    @Test("Relógio retrocedido invalida o pacote em vez de estendê-lo")
    func clockSkew() {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let packet = EvidencePacket(cacheKey: "k", query: makeQuery(mode: .research), response: "r", createdAt: created)
        #expect(!packet.isFresh(at: created.addingTimeInterval(-60), maxAge: .seconds(3600)))
    }

    @Test("Roundtrip Codable do pacote")
    func roundtrip() throws {
        let packet = EvidencePacket(cacheKey: "k", query: makeQuery(), response: "resposta")
        let data = try JSONEncoder().encode(packet)
        let restored = try JSONDecoder().decode(EvidencePacket.self, from: data)
        #expect(restored.cacheKey == packet.cacheKey)
        #expect(restored.query == packet.query)
    }
}

@Suite("Modos")
struct ModeTests {
    @Test("Apenas inspect exige workspace")
    func workspaceRequirement() {
        #expect(Mode.inspect.requiresWorkspace)
        for mode in Mode.allCases where mode != .inspect {
            #expect(!mode.requiresWorkspace)
        }
    }

    @Test("Todos os modos têm modelo e prompt definidos")
    func defaults() {
        for mode in Mode.allCases {
            #expect(!mode.defaultModel.isEmpty)
            #expect(mode.promptFileName == "\(mode.rawValue).md")
            #expect(mode.defaultTimeout.components.seconds > 0)
        }
    }
}

@Suite("Orçamento de resposta")
struct ResponseBudgetTests {
    @Test("Resposta dentro do orçamento passa intacta")
    func withinBudget() {
        let (text, truncated) = ResponseBudget.apply(100, to: "curta")
        #expect(text == "curta")
        #expect(!truncated)
    }

    @Test("Resposta acima do orçamento é cortada e marcada")
    func overBudget() {
        let long = String(repeating: "a", count: 500)
        let (text, truncated) = ResponseBudget.apply(100, to: long)
        #expect(truncated)
        #expect(text.contains("[resposta cortada no orçamento de 100 caracteres]"))
        #expect(text.count < long.count)
    }

    @Test("O corte prefere fronteira de parágrafo quando ela está perto do limite")
    func cutsAtParagraph() {
        let text = String(repeating: "a", count: 80) + "\n\n" + String(repeating: "b", count: 80)
        let (result, truncated) = ResponseBudget.apply(100, to: text)
        #expect(truncated)
        #expect(!result.contains("b"))
        #expect(result.hasPrefix(String(repeating: "a", count: 80)))
    }

    @Test("Parágrafo muito cedo não sacrifica metade do orçamento")
    func doesNotCutTooEarly() {
        let text = "ab\n\n" + String(repeating: "c", count: 300)
        let (result, _) = ResponseBudget.apply(100, to: text)
        #expect(result.contains("c"))
    }

    @Test("Orçamento não positivo desliga o corte")
    func disabledBudget() {
        let long = String(repeating: "a", count: 500)
        #expect(ResponseBudget.apply(0, to: long).text == long)
    }

    @Test("O pacote registra o corte e o tamanho da resposta")
    func packetRecordsTruncation() throws {
        let envelope = AgyEnvelope(response: String(repeating: "a", count: 5000))
        let query = Query(mode: .verify, question: "q", model: "m", promptDigest: "p")
        let packet = EvidencePacket(query: query, envelope: envelope, agyVersion: "1.2.7")
        #expect(packet.truncated)
        #expect(packet.responseCharacters <= Mode.verify.responseBudget + 60)
    }
}
