import Foundation
import XCTest
@testable import DetachKit

final class WorkspaceDependenciesMCPTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "detach-workspace-mcp-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testRuntimeLocatorReturnsOnlyValidatedBundledPaths() throws {
        let root = try makeRuntimeRoot()

        let runtime = try WorkspaceDependenciesRuntime.load(from: root)

        XCTAssertEqual(runtime.bundleVersion, "test-bundle")
        XCTAssertEqual(
            runtime.pythonExecutable.path,
            root.appendingPathComponent(
                "dependencies/python/bin/python3").path)
        XCTAssertTrue(runtime.toolResult.contains(
            "Workspace dependencies are available for this local Codex CLI session."))
        XCTAssertTrue(runtime.toolResult.contains(runtime.nodeExecutable.path))
    }

    func testRuntimeLocatorRejectsARequiredPathOutsideTheBundle() throws {
        let root = try makeRuntimeRoot()
        let python = root.appendingPathComponent(
            "dependencies/python/bin/python3")
        let external = temporaryDirectory.appendingPathComponent("external-python")
        try Data("unsafe".utf8).write(to: external)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: external.path)
        try FileManager.default.removeItem(at: python)
        try FileManager.default.createSymbolicLink(
            at: python, withDestinationURL: external)

        XCTAssertThrowsError(try WorkspaceDependenciesRuntime.load(from: root)) {
            XCTAssertEqual(
                $0 as? WorkspaceDependenciesRuntimeError,
                .unsafePath("dependencies/python/bin/python3"))
        }
    }

    func testMCPProtocolListsAndCallsOnlyTheRuntimeLocator() throws {
        let root = try makeRuntimeRoot()
        let initialize = try response(
            method: "initialize",
            id: 1,
            params: ["protocolVersion": "2025-06-18"],
            runtimeRoot: root)
        let initializeResult = try dictionary(initialize["result"])
        XCTAssertEqual(
            initializeResult["protocolVersion"] as? String,
            "2025-06-18")

        let list = try response(
            method: "tools/list", id: 2, params: [:], runtimeRoot: root)
        let listResult = try dictionary(list["result"])
        let tools = try XCTUnwrap(listResult["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"] as? String, "load_workspace_dependencies")

        let call = try response(
            method: "tools/call",
            id: 3,
            params: ["name": "load_workspace_dependencies", "arguments": [:]],
            runtimeRoot: root)
        let callResult = try dictionary(call["result"])
        XCTAssertEqual(callResult["isError"] as? Bool, false)
        let content = try XCTUnwrap(callResult["content"] as? [[String: Any]])
        XCTAssertTrue((content.first?["text"] as? String)?.contains(
            "test-bundle") == true)
    }

    func testMCPToolReturnsTypedErrorWhenRuntimeIsMissing() throws {
        let missing = temporaryDirectory.appendingPathComponent(
            "missing", isDirectory: true)

        let call = try response(
            method: "tools/call",
            id: "call-1",
            params: ["name": "load_workspace_dependencies", "arguments": [:]],
            runtimeRoot: missing)

        let result = try dictionary(call["result"])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    private func makeRuntimeRoot() throws -> URL {
        let root = temporaryDirectory.appendingPathComponent(
            "codex-primary-runtime", isDirectory: true)
        for directory in [
            "dependencies/bin/fallback",
            "dependencies/bin/override",
            "dependencies/node/bin",
            "dependencies/node/node_modules",
            "dependencies/python/bin",
        ] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true)
        }
        let manifest: [String: Any] = [
            "bundleFormatVersion": 2,
            "bundleVersion": "test-bundle",
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(
            to: root.appendingPathComponent("runtime.json"))
        for relativePath in [
            "dependencies/bin/fallback/git",
            "dependencies/bin/fallback/pnpm",
            "dependencies/node/bin/node",
            "dependencies/python/bin/python3",
        ] {
            let executable = root.appendingPathComponent(relativePath)
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        return root
    }

    private func response(
        method: String,
        id: Any,
        params: [String: Any],
        runtimeRoot: URL
    ) throws -> [String: Any] {
        let request = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ])
        let data = try XCTUnwrap(WorkspaceDependenciesMCPServer.response(
            for: request,
            runtimeRoot: runtimeRoot))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }
}
