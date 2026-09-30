import Foundation
import Darwin

/// Mantém delegações MCP em processos separados sem bloquear o transporte.
///
/// O servidor MCP acessa esta classe por um único loop serial. Os processos
/// filhos podem executar em paralelo, mas nenhum estado Swift é compartilhado
/// entre threads; stdout e stderr vão para arquivos para não encher pipes.
public final class MCPJobManager {
    public enum JobState: String, Sendable, Codable {
        case running
        case completed
        case failed
        case cancelled
    }

    public struct Snapshot: Sendable, Equatable, Codable {
        public var id: String
        public var label: String
        public var state: JobState
        public var startedAt: Date
        public var elapsedSeconds: Double

        public init(id: String, label: String, state: JobState, startedAt: Date, elapsedSeconds: Double) {
            self.id = id
            self.label = label
            self.state = state
            self.startedAt = startedAt
            self.elapsedSeconds = elapsedSeconds
        }
    }

    public enum CollectedResult: Sendable {
        case running(Snapshot)
        case completed(snapshot: Snapshot, output: Data)
        case failed(snapshot: Snapshot, detail: String)
        case cancelled(Snapshot)
    }

    public enum ManagerError: Error, Equatable, CustomStringConvertible {
        case invalidConcurrencyLimit
        case concurrencyLimitReached(Int)
        case unknownJob(String)
        case launchFailed(String)
        case invalidInput(String)

        public var description: String {
            switch self {
            case .invalidConcurrencyLimit:
                "o limite de jobs simultâneos deve ser positivo"
            case .concurrencyLimitReached(let limit):
                "limite de \(limit) jobs simultâneos atingido"
            case .unknownJob(let id):
                "job desconhecido: \(id)"
            case .launchFailed(let detail):
                "não foi possível iniciar o job: \(detail)"
            case .invalidInput(let detail):
                "entrada do job inválida: \(detail)"
            }
        }
    }

    private final class Record {
        let id: String
        let label: String
        let process: Process
        let startedAt: Date
        let outputURL: URL
        let errorURL: URL
        let inputURL: URL?
        let outputHandle: FileHandle
        let errorHandle: FileHandle
        var inputHandle: FileHandle?
        var cancelled = false
        var handlesClosed = false

        init(
            id: String,
            label: String,
            process: Process,
            startedAt: Date,
            outputURL: URL,
            errorURL: URL,
            inputURL: URL?,
            outputHandle: FileHandle,
            errorHandle: FileHandle,
            inputHandle: FileHandle?
        ) {
            self.id = id
            self.label = label
            self.process = process
            self.startedAt = startedAt
            self.outputURL = outputURL
            self.errorURL = errorURL
            self.inputURL = inputURL
            self.outputHandle = outputHandle
            self.errorHandle = errorHandle
            self.inputHandle = inputHandle
        }

        func closeHandles() {
            guard !handlesClosed else { return }
            try? outputHandle.close()
            try? errorHandle.close()
            closeInputHandle()
            handlesClosed = true
        }

        func closeInputHandle() {
            try? inputHandle?.close()
            inputHandle = nil
        }
    }

    private let executable: URL
    private let workingDirectory: URL
    private let outputDirectory: URL
    private let environment: [String: String]
    private let maxConcurrentJobs: Int
    private let maxRetainedJobs: Int
    private let clock: @Sendable () -> Date
    private var records: [String: Record] = [:]

    public init(
        executable: URL,
        workingDirectory: URL,
        outputDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maxConcurrentJobs: Int = 2,
        maxRetainedJobs: Int = 20,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard maxConcurrentJobs > 0 else { throw ManagerError.invalidConcurrencyLimit }
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.outputDirectory = outputDirectory
        self.environment = environment
        self.maxConcurrentJobs = maxConcurrentJobs
        self.maxRetainedJobs = max(maxRetainedJobs, maxConcurrentJobs)
        self.clock = clock

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        Self.removeStaleFiles(in: outputDirectory, before: clock().addingTimeInterval(-24 * 3600))
    }

    deinit {
        for record in records.values {
            if record.process.isRunning { Self.terminateProcessTree(record.process) }
            record.closeHandles()
            try? FileManager.default.removeItem(at: record.outputURL)
            try? FileManager.default.removeItem(at: record.errorURL)
            if let inputURL = record.inputURL { try? FileManager.default.removeItem(at: inputURL) }
        }
    }

    public static let maximumInputBytes = 1_048_576

    public func spawn(arguments: [String], label: String, stdin: Data? = nil) throws -> Snapshot {
        if let stdin {
            guard stdin.count <= Self.maximumInputBytes else {
                throw ManagerError.invalidInput("limite de \(Self.maximumInputBytes) bytes excedido")
            }
            guard !stdin.contains(0) else {
                throw ManagerError.invalidInput("U+0000 não é aceito")
            }
        }
        refreshFinishedJobs()
        let running = records.values.filter { state(of: $0) == .running }.count
        guard running < maxConcurrentJobs else {
            throw ManagerError.concurrencyLimitReached(maxConcurrentJobs)
        }
        pruneRetainedJobsIfNeeded()

        let id = UUID().uuidString.lowercased()
        let outputURL = outputDirectory.appending(path: "\(id).stdout")
        let errorURL = outputDirectory.appending(path: "\(id).stderr")
        let inputURL = stdin.map { _ in outputDirectory.appending(path: "\(id).stdin") }
        try Self.createPrivateFile(at: outputURL)
        do {
            try Self.createPrivateFile(at: errorURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        if let stdin, let inputURL {
            do {
                try Self.createPrivateFile(at: inputURL)
                let inputWriter = try FileHandle(forWritingTo: inputURL)
                defer { try? inputWriter.close() }
                try inputWriter.write(contentsOf: stdin)
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                try? FileManager.default.removeItem(at: errorURL)
                try? FileManager.default.removeItem(at: inputURL)
                throw ManagerError.launchFailed("não foi possível preparar stdin: \(error)")
            }
        }

        var openedOutputHandle: FileHandle?
        var openedErrorHandle: FileHandle?
        var openedInputHandle: FileHandle?
        do {
            openedOutputHandle = try FileHandle(forWritingTo: outputURL)
            openedErrorHandle = try FileHandle(forWritingTo: errorURL)
            openedInputHandle = try inputURL.map { try FileHandle(forReadingFrom: $0) }
        } catch {
            try? openedOutputHandle?.close()
            try? openedErrorHandle?.close()
            try? openedInputHandle?.close()
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
            if let inputURL { try? FileManager.default.removeItem(at: inputURL) }
            throw ManagerError.launchFailed("não foi possível abrir arquivos do job: \(error)")
        }
        guard let outputHandle = openedOutputHandle, let errorHandle = openedErrorHandle else {
            throw ManagerError.launchFailed("descritores de saída indisponíveis")
        }
        let inputHandle = openedInputHandle
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = inputHandle ?? FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        let record = Record(
            id: id,
            label: label,
            process: process,
            startedAt: clock(),
            outputURL: outputURL,
            errorURL: errorURL,
            inputURL: inputURL,
            outputHandle: outputHandle,
            errorHandle: errorHandle,
            inputHandle: inputHandle
        )
        do {
            try process.run()
            records[id] = record
            record.closeInputHandle()
            if let inputURL { try? FileManager.default.removeItem(at: inputURL) }
            return snapshot(for: record)
        } catch {
            record.closeHandles()
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
            if let inputURL { try? FileManager.default.removeItem(at: inputURL) }
            throw ManagerError.launchFailed("\(error)")
        }
    }

    public func spawn(arguments: [String], label: String, stdin: String) throws -> Snapshot {
        try spawn(arguments: arguments, label: label, stdin: Data(stdin.utf8))
    }

    public func status(id: String) throws -> Snapshot {
        guard let record = records[id] else { throw ManagerError.unknownJob(id) }
        closeHandlesIfFinished(record)
        return snapshot(for: record)
    }

    public func collect(id: String) throws -> CollectedResult {
        guard let record = records[id] else { throw ManagerError.unknownJob(id) }
        closeHandlesIfFinished(record)
        let snapshot = snapshot(for: record)
        switch snapshot.state {
        case .running:
            return .running(snapshot)
        case .cancelled:
            return .cancelled(snapshot)
        case .completed:
            return .completed(snapshot: snapshot, output: (try? Data(contentsOf: record.outputURL)) ?? Data())
        case .failed:
            let data = (try? Data(contentsOf: record.errorURL)) ?? Data()
            let detail = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(snapshot: snapshot, detail: String(detail.prefix(1_000)))
        }
    }

    @discardableResult
    public func cancel(id: String) throws -> Snapshot {
        guard let record = records[id] else { throw ManagerError.unknownJob(id) }
        guard record.process.isRunning else {
            record.closeHandles()
            return snapshot(for: record)
        }
        Self.terminateProcessTree(record.process)
        record.cancelled = true
        closeHandlesIfFinished(record)
        return snapshot(for: record)
    }

    private func state(of record: Record) -> JobState {
        if record.cancelled { return .cancelled }
        if record.process.isRunning { return .running }
        return record.process.terminationStatus == 0 ? .completed : .failed
    }

    private func snapshot(for record: Record) -> Snapshot {
        Snapshot(
            id: record.id,
            label: record.label,
            state: state(of: record),
            startedAt: record.startedAt,
            elapsedSeconds: max(0, clock().timeIntervalSince(record.startedAt))
        )
    }

    private func closeHandlesIfFinished(_ record: Record) {
        if !record.process.isRunning { record.closeHandles() }
    }

    private func refreshFinishedJobs() {
        for record in records.values { closeHandlesIfFinished(record) }
    }

    private func pruneRetainedJobsIfNeeded() {
        let excess = records.count - maxRetainedJobs + 1
        guard excess > 0 else { return }
        let removable = records.values
            .filter { state(of: $0) != .running }
            .sorted { $0.startedAt < $1.startedAt }
            .prefix(excess)
        for record in removable {
            record.closeHandles()
            try? FileManager.default.removeItem(at: record.outputURL)
            try? FileManager.default.removeItem(at: record.errorURL)
            if let inputURL = record.inputURL { try? FileManager.default.removeItem(at: inputURL) }
            records.removeValue(forKey: record.id)
        }
    }

    private static func createPrivateFile(at url: URL) throws {
        guard FileManager.default.createFile(
            atPath: url.path(percentEncoded: false),
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ManagerError.launchFailed("não foi possível criar \(url.path(percentEncoded: false))")
        }
    }

    private static func removeStaleFiles(in directory: URL, before cutoff: Date) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.pathExtension == "stdout" || file.pathExtension == "stderr" || file.pathExtension == "stdin" {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Encerra descendentes antes do wrapper para que o processo de trabalho
    /// não seja adotado pelo launchd e continue consumindo recursos sozinho.
    private static func terminateProcessTree(_ process: Process) {
        let descendants = descendantPIDs(of: process.processIdentifier)
        for pid in descendants.reversed() { kill(pid, SIGTERM) }
        process.terminate()

        for _ in 0..<10 {
            if descendants.allSatisfy({ kill($0, 0) != 0 }) && !process.isRunning { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        for pid in descendants.reversed() where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private static func descendantPIDs(of parent: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(filePath: "/usr/bin/pgrep", directoryHint: .notDirectory)
        pgrep.arguments = ["-P", String(parent)]
        pgrep.standardInput = FileHandle.nullDevice
        let output = Pipe()
        pgrep.standardOutput = output
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return [] }
        pgrep.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let children = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) }
        return children + children.flatMap(descendantPIDs(of:))
    }
}
