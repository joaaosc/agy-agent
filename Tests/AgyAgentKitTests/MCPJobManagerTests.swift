import Foundation
import Testing
@testable import AgyAgentKit

@Suite("Jobs MCP")
struct MCPJobManagerTests {
    func manager(_ directory: borrowing TemporaryDirectory, maximum: Int = 2) throws -> MCPJobManager {
        try MCPJobManager(
            executable: URL(filePath: "/bin/sh", directoryHint: .notDirectory),
            workingDirectory: directory.url,
            outputDirectory: directory.url.appending(path: "jobs"),
            environment: ["PATH": "/usr/bin:/bin"],
            maxConcurrentJobs: maximum
        )
    }

    @Test("Spawn devolve imediatamente e o resultado pode ser coletado depois")
    func spawnAndCollect() throws {
        let directory = try TemporaryDirectory()
        let jobs = try manager(directory)
        let spawned = try jobs.spawn(arguments: ["-c", "sleep 0.2; printf resultado"], label: "verify")
        #expect(spawned.state == .running)

        while try jobs.status(id: spawned.id).state == .running {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard case .completed(_, let output) = try jobs.collect(id: spawned.id) else {
            Issue.record("job deveria ter concluído")
            return
        }
        #expect(String(decoding: output, as: UTF8.self) == "resultado")
    }

    @Test("Limite simultâneo impede uma rajada de processos")
    func concurrencyLimit() throws {
        let directory = try TemporaryDirectory()
        let jobs = try manager(directory, maximum: 1)
        let marker = directory.url.appending(path: "nao-deve-existir")
        let first = try jobs.spawn(
            arguments: ["-c", "sleep 1; touch '\(marker.path(percentEncoded: false))'"],
            label: "a"
        )
        #expect(throws: MCPJobManager.ManagerError.concurrencyLimitReached(1)) {
            try jobs.spawn(arguments: ["-c", "sleep 5"], label: "b")
        }
        #expect(try jobs.cancel(id: first.id).state == .cancelled)
        Thread.sleep(forTimeInterval: 1.1)
        #expect(!FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
    }

    @Test("Falha preserva stderr sem devolver stdout como resultado")
    func failureDetail() throws {
        let directory = try TemporaryDirectory()
        let jobs = try manager(directory)
        let spawned = try jobs.spawn(arguments: ["-c", "printf diagnostico >&2; exit 7"], label: "verify")
        while try jobs.status(id: spawned.id).state == .running {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard case .failed(_, let detail) = try jobs.collect(id: spawned.id) else {
            Issue.record("job deveria ter falhado")
            return
        }
        #expect(detail == "diagnostico")
    }

    @Test("Job desconhecido falha explicitamente")
    func unknownJob() throws {
        let directory = try TemporaryDirectory()
        let jobs = try manager(directory)
        #expect(throws: MCPJobManager.ManagerError.unknownJob("ausente")) {
            try jobs.status(id: "ausente")
        }
    }

    @Test("Cancelar depois da conclusão preserva o resultado")
    func cancellingCompletedJobKeepsResult() throws {
        let directory = try TemporaryDirectory()
        let jobs = try manager(directory)
        let spawned = try jobs.spawn(arguments: ["-c", "printf pronto"], label: "verify")
        while try jobs.status(id: spawned.id).state == .running {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(try jobs.cancel(id: spawned.id).state == .completed)
        guard case .completed(_, let output) = try jobs.collect(id: spawned.id) else {
            Issue.record("resultado concluído deveria continuar disponível")
            return
        }
        #expect(String(decoding: output, as: UTF8.self) == "pronto")
    }
}
