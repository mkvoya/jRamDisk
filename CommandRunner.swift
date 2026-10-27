import Foundation
import Darwin

struct CommandResult: Sendable {
    let stdout: Data
    let stderr: Data
    let status: Int32
    var output: String { String(decoding: stdout, as: UTF8.self) }
}

struct CommandFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Each invocation owns its process. Blocking reads never run on the main actor.
struct CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) async throws -> CommandResult {
        let execution = CommandExecution()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try execution.run(executable, arguments, timeout: timeout) })
                }
            }
        } onCancel: {
            execution.stop(reason: "Command cancelled")
        }
    }
}

private final class CommandExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var stopReason: String?
    private var finished = false

    func stop(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        stopReason = stopReason ?? reason
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock()
            defer { lock.unlock() }
            if !finished && process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        let out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err
        lock.lock()
        if let reason = stopReason {
            finished = true
            lock.unlock()
            throw CommandFailure(message: reason)
        }
        do { try process.run() } catch {
            finished = true
            lock.unlock()
            throw error
        }
        lock.unlock()
        let deadline = DispatchWorkItem { [self] in stop(reason: "Command timed out after \(Int(timeout)) seconds") }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

        // Drain both pipes concurrently, including output beyond the retained limit.
        let stderrReader = PipeReader()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stderrReader.read(err.fileHandleForReading)
            group.leave()
        }
        let stdoutReader = PipeReader()
        stdoutReader.read(out.fileHandleForReading)
        process.waitUntilExit()
        group.wait()
        deadline.cancel()
        lock.lock()
        finished = true
        let reason = stopReason
        lock.unlock()
        let result = CommandResult(stdout: stdoutReader.data, stderr: stderrReader.data, status: process.terminationStatus)
        if let reason { throw CommandFailure(message: "\(executable): \(reason)") }
        guard result.status == 0 else {
            let details = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommandFailure(message: "\(executable) exited with status \(result.status): \(details.isEmpty ? result.output : details)")
        }
        return result
    }
}

private final class PipeReader: @unchecked Sendable {
    private(set) var data = Data()
    func read(_ handle: FileHandle) {
        defer { try? handle.close() }
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            let remaining = max(0, 4 * 1024 * 1024 - data.count)
            data.append(chunk.prefix(remaining))
        }
    }
}
