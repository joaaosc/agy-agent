import Foundation

public struct ProcessPlan: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    public var environment: [String: String]
    public var timeout: Duration
    public var standardInput: String?

    public init(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        timeout: Duration,
        standardInput: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.standardInput = standardInput
    }
}

public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String
    public var timedOut: Bool
    public var duration: Double

    public init(
        exitCode: Int32,
        standardOutput: String,
        standardError: String,
        timedOut: Bool = false,
        duration: Double = 0
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
        self.duration = duration
    }
}

/// Execução de subprocesso. O protocolo existe para que o runner do `agy`
/// possa ser testado sem lançar o binário real.
public protocol ProcessRunning: Sendable {
    func run(_ plan: ProcessPlan) throws -> ProcessResult
}

/// Implementação sobre `Foundation.Process`.
public struct SubprocessRunner: ProcessRunning {
    public init() {}

    public func run(_ plan: ProcessPlan) throws -> ProcessResult {
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.workingDirectory
        process.environment = plan.environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let inputPipe = plan.standardInput == nil ? nil : Pipe()
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        let started = Date()
        do {
            try process.run()
        } catch {
            // Culpar o executável por qualquer falha de lançamento mandou uma
            // vez o diagnóstico para o lado errado: o que faltava era o
            // diretório de trabalho.
            let executablePath = plan.executable.path(percentEncoded: false)
            guard FileManager.default.isExecutableFile(atPath: executablePath) else {
                throw AgyAgentError.agyNotFound(executablePath)
            }
            let workingPath = plan.workingDirectory.path(percentEncoded: false)
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: workingPath, isDirectory: &isDirectory) || !isDirectory.boolValue {
                throw AgyAgentError.processLaunchFailed(
                    executable: executablePath,
                    reason: "diretório de trabalho inexistente: \(workingPath)"
                )
            }
            throw AgyAgentError.processLaunchFailed(
                executable: executablePath,
                reason: error.localizedDescription
            )
        }

        if let standardInput = plan.standardInput, let inputPipe {
            inputPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }

        // Os pipes precisam ser drenados enquanto o processo vive: uma saída
        // maior que o buffer do pipe bloquearia o filho para sempre se a
        // leitura só começasse depois do `waitUntilExit`.
        let collector = OutputCollector()
        let readers = DispatchGroup()
        for (handle, isError) in [(outputPipe.fileHandleForReading, false), (errorPipe.fileHandleForReading, true)] {
            DispatchQueue.global(qos: .userInitiated).async(group: readers) {
                let data = handle.readDataToEndOfFile()
                collector.append(data, isError: isError)
            }
        }

        let deadline = DispatchTime.now() + .seconds(Int(plan.timeout.components.seconds))
        let exited = DispatchGroup()
        exited.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.leave()
        }

        var timedOut = false
        if exited.wait(timeout: deadline) == .timedOut {
            timedOut = true
            process.terminate()
            // SIGTERM pode ser ignorado; o encerramento precisa ser garantido.
            if exited.wait(timeout: .now() + .seconds(5)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        readers.wait()

        let result = ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: collector.standardOutput,
            standardError: collector.standardError,
            timedOut: timedOut,
            duration: Date().timeIntervalSince(started)
        )

        if timedOut {
            throw AgyAgentError.timedOut(seconds: Double(plan.timeout.components.seconds))
        }
        return result
    }
}

/// Acumulador com acesso serializado, escrito por duas filas de leitura.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()

    func append(_ data: Data, isError: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isError { error.append(data) } else { output.append(data) }
    }

    var standardOutput: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: output, as: UTF8.self)
    }

    var standardError: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: error, as: UTF8.self)
    }
}
