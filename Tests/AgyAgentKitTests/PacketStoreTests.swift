import Testing
import Foundation
@testable import AgyAgentKit

/// Diretório temporário isolado, removido ao final do teste.
struct TemporaryDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "agy-agent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("Persistência de pacotes")
struct PacketStoreTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    func makeStore(_ directory: borrowing TemporaryDirectory, named name: String = "cache.sqlite", now: Date = PacketStoreTests.now) throws -> PacketStore {
        try PacketStore(url: directory.url.appending(path: "sub/\(name)"), clock: { now })
    }

    func packet(
        key: String = "chave-1",
        mode: Mode = .verify,
        question: String = "A API X existe?",
        response: String = "Confirmado.",
        createdAt: Date = PacketStoreTests.now,
        truncated: Bool = false
    ) -> EvidencePacket {
        EvidencePacket(
            cacheKey: key,
            query: Query(mode: mode, question: question, model: "gemini-3.8-flash-medium", promptDigest: "p"),
            response: response,
            conversationID: "conv-1",
            usage: AgyEnvelope.Usage(inputTokens: 24809, outputTokens: 40, totalTokens: 24849),
            durationSeconds: 2.5,
            agyVersion: "1.2.7",
            createdAt: createdAt,
            truncated: truncated
        )
    }

    @Test("O banco e o diretório são criados sob demanda, com permissão restrita")
    func createsDirectoryLazily() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        #expect(FileManager.default.fileExists(atPath: store.url.path(percentEncoded: false)))

        let parent = store.url.deletingLastPathComponent().path(percentEncoded: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: parent)
        #expect(attributes[.posixPermissions] as? NSNumber == 0o700)
    }

    @Test("Abrir duas vezes é idempotente e preserva o conteúdo")
    func migrationIsIdempotent() throws {
        let directory = try TemporaryDirectory()
        let first = try makeStore(directory)
        try first.store(packet())

        let second = try makeStore(directory)
        #expect(try second.storedPacket(forKey: "chave-1")?.response == "Confirmado.")
        #expect(try second.statistics().packets == 1)
    }

    @Test("Roundtrip preserva consulta, uso e proveniência")
    func roundtrip() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        let original = packet(truncated: true)
        try store.store(original)

        let restored = try #require(try store.storedPacket(forKey: "chave-1"))
        #expect(restored.id == original.id)
        #expect(restored.query == original.query)
        #expect(restored.response == original.response)
        #expect(restored.usage == original.usage)
        #expect(restored.agyVersion == "1.2.7")
        #expect(restored.conversationID == "conv-1")
        #expect(restored.truncated)
        #expect(abs(restored.createdAt.timeIntervalSince(original.createdAt)) < 0.001)
    }

    @Test("Gravar na mesma chave substitui em vez de falhar")
    func upsert() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        try store.store(packet(response: "primeira"))
        try store.store(packet(response: "segunda"))

        #expect(try store.statistics().packets == 1)
        #expect(try store.storedPacket(forKey: "chave-1")?.response == "segunda")
    }

    @Test("A contagem de usos sobrevive à regravação da resposta")
    func hitsSurviveUpsert() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        try store.store(packet())
        try store.recordHit(forKey: "chave-1")
        try store.recordHit(forKey: "chave-1")
        try store.store(packet(response: "nova"))

        // hits mede o uso da chave, não da resposta: zerar esconderia a
        // economia acumulada.
        #expect(try store.statistics().hits == 2)
    }

    @Test("Frescor filtra a leitura de cache dos modos que dependem da web")
    func freshnessFiltersWebModes() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        try store.store(packet(mode: .research, createdAt: Self.now.addingTimeInterval(-7200)))

        #expect(try store.packet(forKey: "chave-1", maxAge: .seconds(3600)) == nil)
        #expect(try store.packet(forKey: "chave-1", maxAge: .seconds(10800)) != nil)
        // O pacote continua armazenado; apenas não é servido como fresco.
        #expect(try store.storedPacket(forKey: "chave-1") != nil)
    }

    @Test("Modos que não dependem da web ignoram o relógio")
    func localModesIgnoreAge() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        try store.store(packet(mode: .summarize, createdAt: Self.now.addingTimeInterval(-10_000_000)))
        #expect(try store.packet(forKey: "chave-1", maxAge: .seconds(60)) != nil)
    }

    @Test("Chave inexistente devolve nil em vez de erro")
    func missingKey() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        #expect(try store.storedPacket(forKey: "não-existe") == nil)
    }

    @Test("Promoção copia o pacote para o banco durável sem removê-lo do cache")
    func promotion() throws {
        let directory = try TemporaryDirectory()
        let cache = try makeStore(directory, named: "cache.sqlite")
        let knowledge = try makeStore(directory, named: "knowledge.sqlite")
        try cache.store(packet())

        try cache.promote(key: "chave-1", to: knowledge)
        #expect(try knowledge.storedPacket(forKey: "chave-1")?.response == "Confirmado.")
        #expect(try cache.storedPacket(forKey: "chave-1") != nil)
    }

    @Test("Promover chave inexistente falha explicitamente")
    func promotionOfMissingKey() throws {
        let directory = try TemporaryDirectory()
        let cache = try makeStore(directory, named: "cache.sqlite")
        let knowledge = try makeStore(directory, named: "knowledge.sqlite")
        #expect(throws: AgyAgentError.self) {
            try cache.promote(key: "ausente", to: knowledge)
        }
    }

    @Test("As estatísticas medem contexto poupado, não tokens do agy")
    func statistics() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        try store.store(packet(key: "a", response: String(repeating: "x", count: 100)))
        try store.store(packet(key: "b", response: String(repeating: "y", count: 50), truncated: true))
        try store.recordHit(forKey: "a")
        try store.recordHit(forKey: "a")
        try store.recordHit(forKey: "b")

        let statistics = try store.statistics()
        #expect(statistics.packets == 2)
        #expect(statistics.hits == 3)
        #expect(statistics.responseCharacters == 150)
        #expect(statistics.truncated == 1)
        // 2 usos de 100 + 1 uso de 50 caracteres que não custaram chamada.
        #expect(statistics.charactersServedFromCache == 250)
        #expect(statistics.agyTokens == 2 * 24849)
        // output_tokens é o custo do turno no agy, não o tamanho da resposta.
        #expect(statistics.agyOutputTokens == 2 * 40)
        #expect(statistics.agyOutputTokensAvoided == 3 * 40)
        // A economia no chamador é estimada a partir dos caracteres.
        #expect(statistics.estimatedCallerTokensSaved == 250 / 4)
    }

    @Test("Estatísticas de banco vazio são zeradas")
    func emptyStatistics() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        #expect(try store.statistics() == PacketStore.Statistics())
    }

    @Test("Poda remove apenas o que passou da idade")
    func prune() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        try store.store(packet(key: "velho", createdAt: Self.now.addingTimeInterval(-90_000)))
        try store.store(packet(key: "novo", createdAt: Self.now))

        let removed = try store.prune(olderThan: .seconds(86_400))
        #expect(removed == 1)
        #expect(try store.storedPacket(forKey: "velho") == nil)
        #expect(try store.storedPacket(forKey: "novo") != nil)
    }

    @Test("Remoção explícita apaga a linha")
    func remove() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        try store.store(packet())
        try store.remove(key: "chave-1")
        #expect(try store.storedPacket(forKey: "chave-1") == nil)
    }

    @Test("Listagem vem da mais recente para a mais antiga")
    func listingOrder() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        try store.store(packet(key: "antiga", createdAt: Self.now.addingTimeInterval(-100)))
        try store.store(packet(key: "recente", createdAt: Self.now))

        let packets = try store.allPackets()
        #expect(packets.map(\.cacheKey) == ["recente", "antiga"])
    }

    @Test("Duas conexões escrevem no mesmo banco sem erro de lock")
    func concurrentWriters() throws {
        let directory = try TemporaryDirectory()
        // Duas sessões (Codex e Claude Code) chamando a ferramenta ao mesmo
        // tempo é o caso normal; sem WAL e busy_timeout isto daria
        // SQLITE_BUSY.
        let first = try makeStore(directory)
        let second = try makeStore(directory)

        let group = DispatchGroup()
        let failures = FailureBox()
        for (index, store) in [first, second].enumerated() {
            DispatchQueue.global().async(group: group) {
                for item in 0..<25 {
                    do {
                        try store.store(self.packet(key: "chave-\(index)-\(item)"))
                    } catch {
                        failures.record(error)
                    }
                }
            }
        }
        group.wait()

        #expect(failures.errors.isEmpty)
        #expect(try first.statistics().packets == 50)
    }
}

final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [any Error] = []

    func record(_ error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(error)
    }

    var errors: [any Error] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
