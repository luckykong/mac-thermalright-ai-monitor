import Foundation
import Testing
@testable import MacTR

@Suite("Custom script card")
struct CustomScriptRunnerTests {
    @Test("Shell paths are passed as one zsh argument")
    func shellLaunchPolicy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTR Script Policy", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("status card.sh")
        try Data("#!/bin/zsh\nprintf OK\n".utf8).write(to: script)

        let invocation = try CustomScriptLaunchPolicy.invocation(for: script.path)
        #expect(invocation.executablePath == "/bin/zsh")
        #expect(invocation.arguments == [script.path])
        #expect(invocation.workingDirectory == directory.path)
    }

    @Test("Non-shell files require execute permission and run directly")
    func executableLaunchPolicy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("status.py")
        try Data("#!/usr/bin/env python3\nprint('OK')\n".utf8).write(to: script)

        #expect(throws: CustomScriptRunnerError.self) {
            _ = try CustomScriptLaunchPolicy.invocation(for: script.path)
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: script.path)
        let invocation = try CustomScriptLaunchPolicy.invocation(for: script.path)
        #expect(invocation.executablePath == script.path)
        #expect(invocation.arguments.isEmpty)
        #expect(invocation.workingDirectory == directory.path)
    }

    @Test("Executable non-shell files require a shebang")
    func executableNeedsShebang() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("status.py")
        try Data("print('OK')\n".utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: script.path)

        #expect(throws: CustomScriptRunnerError.self) {
            _ = try CustomScriptLaunchPolicy.invocation(for: script.path)
        }
    }

    @Test("ANSI and control characters are removed from card output")
    func outputSanitization() {
        let value = "\u{001B}[31mRED\u{001B}[0m\u{0000}\nNEXT"
        #expect(CustomScriptRunner.sanitizeOutput(value) == "RED\nNEXT")
    }

    @Test("Runner captures plain text without executable permission")
    func runnerCapturesShellOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("card.sh")
        try Data("#!/bin/zsh\nprintf 'STATUS  OK\\nCOUNT   12\\n'\n".utf8)
            .write(to: script)

        let runner = CustomScriptRunner()
        runner.start(configuration: CustomScriptConfiguration(
            enabled: true,
            path: script.path,
            displayName: "Test",
            intervalSeconds: 60))
        defer { runner.stop() }

        var result = runner.currentSnapshot()
        for _ in 0..<80 where result.state != .succeeded {
            try await Task.sleep(for: .milliseconds(25))
            result = runner.currentSnapshot()
        }
        #expect(result.state == .succeeded)
        #expect(result.output == "STATUS  OK\nCOUNT   12")
        #expect(result.exitCode == 0)
    }

    @Test("Intervals clamp to the supported range")
    func intervalClamping() {
        let tooFast = CustomScriptConfiguration(
            enabled: true, path: "/tmp/a.sh", displayName: "", intervalSeconds: 1)
        let tooSlow = CustomScriptConfiguration(
            enabled: true, path: "/tmp/a.sh", displayName: "", intervalSeconds: 100_000)
        #expect(tooFast.normalizedIntervalSeconds == 5)
        #expect(tooSlow.normalizedIntervalSeconds == 86_400)
    }
}
