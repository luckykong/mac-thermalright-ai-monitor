// CustomScriptRunner.swift — sandbox-free, user-configured text card source
//
// The runner never invokes a command string. Shell files are passed as a single
// argument to the system zsh; every other file must be directly executable and
// provide its own shebang/runtime.

import Darwin
import Foundation

enum CustomScriptRunState: String, Sendable {
    case disabled
    case unconfigured
    case ready
    case running
    case succeeded
    case failed
    case timedOut
    case missing
    case invalid
}

struct CustomScriptConfiguration: Equatable, Sendable {
    let enabled: Bool
    let path: String
    let displayName: String
    let intervalSeconds: Int

    static let disabled = CustomScriptConfiguration(
        enabled: false, path: "", displayName: "", intervalSeconds: 60)

    var normalizedIntervalSeconds: Int {
        min(max(intervalSeconds, 5), 86_400)
    }

    var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard !path.isEmpty else { return "CUSTOM" }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}

struct CustomScriptSnapshot: Equatable, Sendable {
    let state: CustomScriptRunState
    let title: String
    let output: String
    let message: String?
    let lastRunAt: Date?
    let exitCode: Int32?

    static let disabled = CustomScriptSnapshot(
        state: .disabled, title: "CUSTOM", output: "",
        message: nil, lastRunAt: nil, exitCode: nil)
}

struct CustomScriptInvocation: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let workingDirectory: String
}

enum CustomScriptLaunchPolicy {
    static func invocation(
        for path: String,
        fileManager: FileManager = .default
    ) throws -> CustomScriptInvocation {
        guard !path.isEmpty, fileManager.fileExists(atPath: path) else {
            throw CustomScriptRunnerError.missing
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw CustomScriptRunnerError.invalid("Select a script file, not a folder.")
        }

        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if ["sh", "zsh", "command"].contains(ext) {
            return CustomScriptInvocation(
                executablePath: "/bin/zsh",
                arguments: [path],
                workingDirectory: url.deletingLastPathComponent().path)
        }

        guard fileManager.isExecutableFile(atPath: path) else {
            throw CustomScriptRunnerError.invalid(
                "The selected file needs execute permission and a valid shebang.")
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw CustomScriptRunnerError.invalid("The selected script could not be read.")
        }
        defer { try? handle.close() }
        guard (try? handle.read(upToCount: 2)) == Data([0x23, 0x21]) else {
            throw CustomScriptRunnerError.invalid(
                "The selected executable needs a valid #! shebang.")
        }
        return CustomScriptInvocation(
            executablePath: path,
            arguments: [],
            workingDirectory: url.deletingLastPathComponent().path)
    }
}

enum CustomScriptRunnerError: Error, Equatable {
    case missing
    case invalid(String)
}

private final class ScriptOutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private(set) var overflowed = false

    init(limit: Int) {
        self.limit = limit
    }

    @discardableResult
    func append(_ newData: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !newData.isEmpty else { return overflowed }
        let remaining = max(limit - data.count, 0)
        if remaining > 0 {
            data.append(newData.prefix(remaining))
        }
        if newData.count > remaining {
            overflowed = true
        }
        return overflowed
    }

    func string() -> String {
        lock.lock()
        let copy = data
        let didOverflow = overflowed
        lock.unlock()

        var value = String(decoding: copy, as: UTF8.self)
        value = CustomScriptRunner.sanitizeOutput(value)
        if didOverflow {
            value += value.isEmpty ? "Output limit reached." : "\n… output truncated"
        }
        return value
    }
}

final class CustomScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.beret21.MacTR.custom-script",
        qos: .utility)
    private let stateLock = NSLock()

    private var timer: DispatchSourceTimer?
    private var configuration = CustomScriptConfiguration.disabled
    private var started = false
    private var currentProcess: Process?
    private var snapshot = CustomScriptSnapshot.disabled
    private var lastSuccessfulOutput = ""

    func start(configuration: CustomScriptConfiguration) {
        queue.async { [weak self] in
            guard let self else { return }
            self.started = true
            self.apply(configuration: configuration, runImmediately: true)
        }
    }

    func update(configuration: CustomScriptConfiguration) {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.apply(configuration: configuration, runImmediately: true)
        }
    }

    func stop() {
        terminateCurrentProcess()
        queue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.timer?.cancel()
            self.timer = nil
        }
    }

    func runNow() {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.executeCurrentConfiguration()
        }
    }

    func currentSnapshot() -> CustomScriptSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return snapshot
    }

    private func apply(
        configuration newConfiguration: CustomScriptConfiguration,
        runImmediately: Bool
    ) {
        let normalized = CustomScriptConfiguration(
            enabled: newConfiguration.enabled,
            path: newConfiguration.path,
            displayName: newConfiguration.displayName,
            intervalSeconds: newConfiguration.normalizedIntervalSeconds)
        let previousConfiguration = configuration
        let hadTimer = timer != nil

        if normalized == previousConfiguration,
           hadTimer || !normalized.enabled || normalized.path.isEmpty
        {
            return
        }

        let schedulingUnchanged =
            normalized.enabled == previousConfiguration.enabled
                && normalized.path == previousConfiguration.path
                && normalized.intervalSeconds
                    == previousConfiguration.intervalSeconds
        configuration = normalized

        if schedulingUnchanged, hadTimer {
            let previous = currentSnapshot()
            updateSnapshot(CustomScriptSnapshot(
                state: previous.state,
                title: configuration.resolvedDisplayName,
                output: previous.output,
                message: previous.message,
                lastRunAt: previous.lastRunAt,
                exitCode: previous.exitCode))
            return
        }

        timer?.cancel()
        timer = nil

        guard configuration.enabled else {
            updateSnapshot(CustomScriptSnapshot(
                state: .disabled,
                title: configuration.resolvedDisplayName,
                output: lastSuccessfulOutput,
                message: nil,
                lastRunAt: currentSnapshot().lastRunAt,
                exitCode: currentSnapshot().exitCode))
            return
        }
        guard !configuration.path.isEmpty else {
            updateSnapshot(CustomScriptSnapshot(
                state: .unconfigured,
                title: configuration.resolvedDisplayName,
                output: "",
                message: "Choose a script in Settings.",
                lastRunAt: nil,
                exitCode: nil))
            return
        }

        let previous = currentSnapshot()
        let shouldRunImmediately = runImmediately
            && (!hadTimer
                || !previousConfiguration.enabled
                || previousConfiguration.path != configuration.path)
        if shouldRunImmediately {
            updateSnapshot(CustomScriptSnapshot(
                state: .ready,
                title: configuration.resolvedDisplayName,
                output: lastSuccessfulOutput,
                message: nil,
                lastRunAt: previous.lastRunAt,
                exitCode: previous.exitCode))
        } else {
            updateSnapshot(CustomScriptSnapshot(
                state: previous.state,
                title: configuration.resolvedDisplayName,
                output: previous.output,
                message: previous.message,
                lastRunAt: previous.lastRunAt,
                exitCode: previous.exitCode))
        }

        let source = DispatchSource.makeTimerSource(queue: queue)
        let interval = configuration.normalizedIntervalSeconds
        source.schedule(
            deadline: shouldRunImmediately ? .now() : .now() + .seconds(interval),
            repeating: .seconds(interval),
            leeway: .milliseconds(min(max(interval * 50, 100), 1_000)))
        source.setEventHandler { [weak self] in
            self?.executeCurrentConfiguration()
        }
        timer = source
        source.resume()
    }

    private func executeCurrentConfiguration() {
        guard started, configuration.enabled else { return }

        let invocation: CustomScriptInvocation
        do {
            invocation = try CustomScriptLaunchPolicy.invocation(for: configuration.path)
        } catch CustomScriptRunnerError.missing {
            publishFailure(state: .missing, message: "Script file not found.", exitCode: nil)
            return
        } catch CustomScriptRunnerError.invalid(let message) {
            publishFailure(state: .invalid, message: message, exitCode: nil)
            return
        } catch {
            publishFailure(state: .invalid, message: error.localizedDescription, exitCode: nil)
            return
        }

        let previous = currentSnapshot()
        updateSnapshot(CustomScriptSnapshot(
            state: .running,
            title: configuration.resolvedDisplayName,
            output: lastSuccessfulOutput,
            message: "Running…",
            lastRunAt: previous.lastRunAt,
            exitCode: previous.exitCode))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: invocation.workingDirectory)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.normalizedPATH(environment["PATH"])
        environment["MACTR_SCRIPT"] = "1"
        environment["MACTR_RUN_AT"] = ISO8601DateFormatter().string(from: Date())
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let accumulator = ScriptOutputAccumulator(limit: 8 * 1024)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if accumulator.append(data) {
                self?.terminateCurrentProcess()
            }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        stateLock.lock()
        currentProcess = process
        stateLock.unlock()

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            clearCurrentProcess(process)
            publishFailure(
                state: .failed,
                message: error.localizedDescription,
                exitCode: nil,
                at: startedAt)
            return
        }

        let timeout = min(
            30,
            max(2, Int(Double(configuration.normalizedIntervalSeconds) * 0.8)))
        let timedOut = finished.wait(timeout: .now() + .seconds(timeout)) == .timedOut
        if timedOut {
            terminate(process)
            _ = finished.wait(timeout: .now() + .seconds(2))
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + .seconds(1))
            }
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        accumulator.append(pipe.fileHandleForReading.readDataToEndOfFile())
        clearCurrentProcess(process)
        let output = accumulator.string()

        if timedOut {
            publishFailure(
                state: .timedOut,
                message: "Timed out after \(timeout)s.",
                exitCode: process.terminationStatus,
                at: startedAt)
        } else if process.terminationStatus == 0 {
            lastSuccessfulOutput = output.isEmpty ? "(no output)" : output
            updateSnapshot(CustomScriptSnapshot(
                state: .succeeded,
                title: configuration.resolvedDisplayName,
                output: lastSuccessfulOutput,
                message: nil,
                lastRunAt: startedAt,
                exitCode: 0))
        } else {
            let detail = output.isEmpty
                ? "Exited with status \(process.terminationStatus)."
                : output
            publishFailure(
                state: .failed,
                message: detail,
                exitCode: process.terminationStatus,
                at: startedAt)
        }
    }

    private func publishFailure(
        state: CustomScriptRunState,
        message: String,
        exitCode: Int32?,
        at date: Date = Date()
    ) {
        updateSnapshot(CustomScriptSnapshot(
            state: state,
            title: configuration.resolvedDisplayName,
            output: lastSuccessfulOutput,
            message: message,
            lastRunAt: date,
            exitCode: exitCode))
    }

    private func updateSnapshot(_ value: CustomScriptSnapshot) {
        stateLock.lock()
        snapshot = value
        stateLock.unlock()
    }

    private func terminateCurrentProcess() {
        stateLock.lock()
        let process = currentProcess
        stateLock.unlock()
        if let process {
            terminate(process)
        }
    }

    private func clearCurrentProcess(_ process: Process) {
        stateLock.lock()
        if currentProcess === process {
            currentProcess = nil
        }
        stateLock.unlock()
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
    }

    static func sanitizeOutput(_ value: String) -> String {
        let ansiPattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
        let withoutANSI = value.replacingOccurrences(
            of: ansiPattern, with: "", options: .regularExpression)
        let scalars = withoutANSI.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t"
                || (!CharacterSet.controlCharacters.contains(scalar))
        }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedPATH(_ current: String?) -> String {
        let defaults = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "/bin", "/usr/sbin", "/sbin",
        ]
        let existing = (current ?? "")
            .split(separator: ":")
            .map(String.init)
        var seen = Set<String>()
        return (existing + defaults)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }
}
