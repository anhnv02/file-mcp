import Foundation
import Darwin

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

enum ProcessRunnerError: LocalizedError {
    case invalidInput(String)
    case spawnFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .invalidInput(message):
            return message
        case let .spawnFailed(executable, code):
            return "Could not launch \(executable) (errno \(code): \(String(cString: strerror(code))))."
        }
    }
}

private final class BoundedDataBuffer {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var omittedBytes = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }

        let remaining = max(0, limit - data.count)
        if remaining > 0 {
            data.append(chunk.prefix(remaining))
        }
        if chunk.count > remaining {
            omittedBytes += chunk.count - remaining
        }
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }

        var text = String(decoding: data, as: UTF8.self)
        if omittedBytes > 0 {
            text += "\n\n[...truncated \(omittedBytes) bytes...]"
        }
        return text
    }
}

private struct SpawnHandles {
    let pid: pid_t
    let stdoutRead: FileHandle
    let stderrRead: FileHandle
}

final class ProcessRunner {
    static let maxCommandTimeoutSeconds = 120
    static let defaultCommandTimeoutSeconds = 30
    static let defaultOutputLimitBytes = 1_000_000

    fileprivate static let readerQueue = DispatchQueue(
        label: "com.filemcp.process-reader",
        qos: .utility,
        attributes: .concurrent
    )

    static func run(
        executable: String,
        arguments: [String],
        cwd: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeoutSeconds: Int,
        outputLimitBytes: Int = defaultOutputLimitBytes,
        shouldCancel: (() -> Bool)? = nil
    ) throws -> ProcessResult {
        let handles = try spawn(
            executable: executable,
            arguments: arguments,
            cwd: cwd,
            environment: environment
        )

        let stdoutBuffer = BoundedDataBuffer(limit: outputLimitBytes)
        let stderrBuffer = BoundedDataBuffer(limit: outputLimitBytes)
        let readers = DispatchGroup()
        drain(handles.stdoutRead, into: stdoutBuffer, group: readers)
        drain(handles.stderrRead, into: stderrBuffer, group: readers)

        let timeout = max(1, min(timeoutSeconds, maxCommandTimeoutSeconds))
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        var status: Int32 = 0
        var timedOut = false
        var didExit = false
        var cancellationRequested = false

        while Date() < deadline {
            if shouldCancel?() == true {
                cancellationRequested = true
                break
            }

            let result = waitpid(handles.pid, &status, WNOHANG)
            if result == handles.pid {
                didExit = true
                break
            }
            if result == -1 && errno == ECHILD {
                didExit = true
                break
            }
            usleep(20_000)
        }

        if !didExit {
            timedOut = !cancellationRequested
            terminateProcessGroup(handles.pid, graceSeconds: 1.0)
            while true {
                let result = waitpid(handles.pid, &status, 0)
                if result == handles.pid || (result == -1 && errno == ECHILD) {
                    break
                }
                if result == -1 && errno != EINTR {
                    break
                }
            }
        } else {
            // A shell can exit successfully while background descendants keep the
            // process group (and our stdout/stderr pipes) alive. Tool execution is
            // one-shot, so do not leak those descendants beyond the tool call.
            terminateProcessGroup(handles.pid, graceSeconds: 0.25)
        }

        _ = readers.wait(timeout: .now() + 2)
        handles.stdoutRead.closeFile()
        handles.stderrRead.closeFile()

        return ProcessResult(
            exitCode: decodeExitCode(status),
            stdout: stdoutBuffer.string(),
            stderr: stderrBuffer.string(),
            timedOut: timedOut
        )
    }

    static func startManaged(
        executable: String,
        arguments: [String],
        cwd: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        onOutput: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws -> ManagedProcess {
        let handles = try spawn(
            executable: executable,
            arguments: arguments,
            cwd: cwd,
            environment: environment
        )
        return ManagedProcess(handles: handles, onOutput: onOutput, onExit: onExit)
    }

    private static func spawn(
        executable: String,
        arguments: [String],
        cwd: String?,
        environment: [String: String]
    ) throws -> SpawnHandles {
        try validatePOSIXStrings(executable: executable, arguments: arguments, cwd: cwd, environment: environment)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutReadFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let stdoutWriteFD = stdoutPipe.fileHandleForWriting.fileDescriptor
        let stderrReadFD = stderrPipe.fileHandleForReading.fileDescriptor
        let stderrWriteFD = stderrPipe.fileHandleForWriting.fileDescriptor

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutWriteFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrWriteFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdoutReadFD)
        posix_spawn_file_actions_addclose(&actions, stderrReadFD)
        posix_spawn_file_actions_addclose(&actions, stdoutWriteFD)
        posix_spawn_file_actions_addclose(&actions, stderrWriteFD)
        if let cwd, !cwd.isEmpty {
            if #available(macOS 26.0, *) {
                posix_spawn_file_actions_addchdir(&actions, cwd)
            } else {
                posix_spawn_file_actions_addchdir_np(&actions, cwd)
            }
        }

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        posix_spawnattr_setflags(&attributes, flags)
        posix_spawnattr_setpgroup(&attributes, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer {
            for pointer in argv {
                if let pointer { free(pointer) }
            }
        }

        let environmentStrings = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var envp: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { strdup($0) }
        envp.append(nil)
        defer {
            for pointer in envp {
                if let pointer { free(pointer) }
            }
        }

        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { envBuffer in
                posix_spawn(
                    &pid,
                    executable,
                    &actions,
                    &attributes,
                    argvBuffer.baseAddress,
                    envBuffer.baseAddress
                )
            }
        }

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        guard result == 0 else {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            throw ProcessRunnerError.spawnFailed(executable, result)
        }

        return SpawnHandles(
            pid: pid,
            stdoutRead: stdoutPipe.fileHandleForReading,
            stderrRead: stderrPipe.fileHandleForReading
        )
    }

    private static func validatePOSIXStrings(
        executable: String,
        arguments: [String],
        cwd: String?,
        environment: [String: String]
    ) throws {
        guard !executable.utf8.contains(0) else {
            throw ProcessRunnerError.invalidInput("Executable path contains a NUL byte.")
        }
        for argument in arguments where argument.utf8.contains(0) {
            throw ProcessRunnerError.invalidInput("Process argument contains a NUL byte.")
        }
        if let cwd, cwd.utf8.contains(0) {
            throw ProcessRunnerError.invalidInput("Working directory contains a NUL byte.")
        }
        for (key, value) in environment {
            guard !key.isEmpty, !key.contains("="), !key.utf8.contains(0) else {
                throw ProcessRunnerError.invalidInput("Environment variable name is not valid for POSIX process execution.")
            }
            guard !value.utf8.contains(0) else {
                throw ProcessRunnerError.invalidInput("Environment variable value contains a NUL byte.")
            }
        }
    }

    private static func drain(
        _ handle: FileHandle,
        into buffer: BoundedDataBuffer,
        group: DispatchGroup
    ) {
        group.enter()
        readerQueue.async {
            defer { group.leave() }
            do {
                while let chunk = try handle.read(upToCount: 16_384), !chunk.isEmpty {
                    buffer.append(chunk)
                }
            } catch {
                // The owner may close the descriptor after process-group cleanup.
                // Treat that close race like EOF instead of letting FileHandle abort.
            }
        }
    }

    static func terminateProcessGroup(_ pid: pid_t, graceSeconds: TimeInterval = 2.0) {
        guard pid > 0 else { return }
        if killpg(pid, SIGTERM) != 0 && errno == ESRCH {
            return
        }

        let deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline {
            if killpg(pid, 0) != 0 && errno == ESRCH {
                return
            }
            usleep(50_000)
        }
        _ = killpg(pid, SIGKILL)
    }

    fileprivate static func decodeExitCode(_ status: Int32) -> Int32 {
        if (status & 0x7f) == 0 {
            return (status >> 8) & 0xff
        }
        let signal = status & 0x7f
        return signal == 0 ? status : 128 + signal
    }
}

final class ManagedProcess {
    private let pid: pid_t
    private let stdoutRead: FileHandle
    private let stderrRead: FileHandle
    private let stateLock = NSLock()
    private let readerGroup = DispatchGroup()
    private var running = true
    private let onOutput: (String) -> Void
    private let onExit: (Int32) -> Void

    fileprivate init(
        handles: SpawnHandles,
        onOutput: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) {
        pid = handles.pid
        stdoutRead = handles.stdoutRead
        stderrRead = handles.stderrRead
        self.onOutput = onOutput
        self.onExit = onExit
        startReaders()
        startWaiter()
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    func stop() {
        stateLock.lock()
        let shouldStop = running
        stateLock.unlock()
        guard shouldStop else { return }

        let targetPID = pid
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessRunner.terminateProcessGroup(targetPID, graceSeconds: 2.0)
        }
    }

    func stopSynchronously() {
        stateLock.lock()
        let shouldStop = running
        stateLock.unlock()
        guard shouldStop else { return }
        ProcessRunner.terminateProcessGroup(pid, graceSeconds: 1.0)
    }

    private func startReaders() {
        let output = onOutput
        readerGroup.enter()
        ProcessRunner.readerQueue.async { [stdoutRead, readerGroup] in
            defer { readerGroup.leave() }
            do {
                while let data = try stdoutRead.read(upToCount: 16_384), !data.isEmpty {
                    output(String(decoding: data, as: UTF8.self))
                }
            } catch {
                // A coordinated shutdown can close the descriptor while a reader is blocked.
            }
        }
        readerGroup.enter()
        ProcessRunner.readerQueue.async { [stderrRead, readerGroup] in
            defer { readerGroup.leave() }
            do {
                while let data = try stderrRead.read(upToCount: 16_384), !data.isEmpty {
                    output(String(decoding: data, as: UTF8.self))
                }
            } catch {
                // A coordinated shutdown can close the descriptor while a reader is blocked.
            }
        }
    }

    private func startWaiter() {
        let targetPID = pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while true {
                let result = waitpid(targetPID, &status, 0)
                if result == targetPID || (result == -1 && errno == ECHILD) {
                    break
                }
                if result == -1 && errno != EINTR {
                    break
                }
            }

            guard let self else { return }
            // A managed parent can exit while descendants still hold inherited pipe
            // descriptors. End the whole process group, give readers a chance to
            // observe EOF, then close any remaining descriptors.
            ProcessRunner.terminateProcessGroup(targetPID, graceSeconds: 0.25)
            _ = self.readerGroup.wait(timeout: .now() + 1)
            self.stdoutRead.closeFile()
            self.stderrRead.closeFile()
            self.stateLock.lock()
            self.running = false
            self.stateLock.unlock()
            self.onExit(ProcessRunner.decodeExitCode(status))
        }
    }
}
