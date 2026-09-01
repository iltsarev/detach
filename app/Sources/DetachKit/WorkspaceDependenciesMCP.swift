import Foundation

enum WorkspaceDependenciesRuntimeError: Error, Equatable {
    case invalidManifest
    case missingPath(String)
    case unsafePath(String)
}

struct WorkspaceDependenciesRuntime: Equatable {
    let bundleVersion: String
    let gitExecutable: URL
    let nodeExecutable: URL
    let nodePackages: URL
    let pnpmExecutable: URL
    let pythonExecutable: URL
    let pythonPackages: URL
    let overrideBinaries: URL
    let fallbackBinaries: URL

    static func load(
        from root: URL,
        fileManager: FileManager = .default
    ) throws -> WorkspaceDependenciesRuntime {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let manifestURL = canonicalRoot.appendingPathComponent("runtime.json")
        guard let data = fileManager.contents(atPath: manifestURL.path),
              let manifest = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let bundleVersion = manifest["bundleVersion"] as? String,
              !bundleVersion.isEmpty,
              let format = manifest["bundleFormatVersion"] as? NSNumber,
              format.intValue >= 1 else {
            throw WorkspaceDependenciesRuntimeError.invalidManifest
        }

        func checked(
            _ relativePath: String,
            kind: URLResourceKey
        ) throws -> URL {
            let candidate = canonicalRoot.appendingPathComponent(relativePath)
                .resolvingSymlinksInPath().standardizedFileURL
            let rootPrefix = canonicalRoot.path.hasSuffix("/")
                ? canonicalRoot.path : canonicalRoot.path + "/"
            guard candidate.path.hasPrefix(rootPrefix) else {
                throw WorkspaceDependenciesRuntimeError.unsafePath(relativePath)
            }
            guard let values = try? candidate.resourceValues(forKeys: [kind]) else {
                throw WorkspaceDependenciesRuntimeError.missingPath(relativePath)
            }
            switch kind {
            case .isDirectoryKey where values.isDirectory == true:
                return candidate
            case .isRegularFileKey where values.isRegularFile == true:
                return candidate
            default:
                throw WorkspaceDependenciesRuntimeError.missingPath(relativePath)
            }
        }

        let git = try checked(
            "dependencies/bin/fallback/git", kind: .isRegularFileKey)
        let node = try checked(
            "dependencies/node/bin/node", kind: .isRegularFileKey)
        let nodePackages = try checked(
            "dependencies/node/node_modules", kind: .isDirectoryKey)
        let pnpm = try checked(
            "dependencies/bin/fallback/pnpm", kind: .isRegularFileKey)
        let python = try checked(
            "dependencies/python/bin/python3", kind: .isRegularFileKey)
        let pythonPackages = try checked(
            "dependencies/python", kind: .isDirectoryKey)
        let overrideBinaries = try checked(
            "dependencies/bin/override", kind: .isDirectoryKey)
        let fallbackBinaries = try checked(
            "dependencies/bin/fallback", kind: .isDirectoryKey)

        for executable in [git, node, pnpm, python]
            where !fileManager.isExecutableFile(atPath: executable.path) {
            throw WorkspaceDependenciesRuntimeError.missingPath(
                executable.lastPathComponent)
        }

        return WorkspaceDependenciesRuntime(
            bundleVersion: bundleVersion,
            gitExecutable: git,
            nodeExecutable: node,
            nodePackages: nodePackages,
            pnpmExecutable: pnpm,
            pythonExecutable: python,
            pythonPackages: pythonPackages,
            overrideBinaries: overrideBinaries,
            fallbackBinaries: fallbackBinaries)
    }

    var toolResult: String {
        """
        Workspace dependencies are available for this local Codex CLI session.

        ### Workspace Dependencies
        Use these bundled paths for documents, images, or browser automation:
        - Bundle version: `\(bundleVersion)`
        - Git executable: `\(gitExecutable.path)`
        - Node.js executable: `\(nodeExecutable.path)`
        - Node.js packages: `\(nodePackages.path)`
        - pnpm executable: `\(pnpmExecutable.path)`
        - Python executable: `\(pythonExecutable.path)`
        - Python packages: `\(pythonPackages.path)`
        - Override binaries: `\(overrideBinaries.path)`
        - Fallback binaries: `\(fallbackBinaries.path)`
        """
    }
}

public enum WorkspaceDependenciesMCPServer {
    public static func serve() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let request = line.data(using: .utf8),
                  let response = response(for: request) else {
                continue
            }
            FileHandle.standardOutput.write(response)
            FileHandle.standardOutput.write(Data([0x0a]))
        }
    }

    static func response(
        for request: Data,
        runtimeRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: request),
              let message = object as? [String: Any] else {
            return encode(errorResponse(
                id: NSNull(), code: -32700, message: "Parse error"))
        }

        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id == nil ? nil : encode(errorResponse(
                id: id ?? NSNull(), code: -32600, message: "Invalid Request"))
        }
        guard let id else { return nil }

        switch method {
        case "initialize":
            let params = message["params"] as? [String: Any]
            let requestedVersion = params?["protocolVersion"] as? String
                ?? "2025-06-18"
            return encode([
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "protocolVersion": requestedVersion,
                    "capabilities": ["tools": [:]],
                    "serverInfo": [
                        "name": "detach-workspace-dependencies",
                        "title": "Detach Workspace Dependencies",
                        "version": "1.0.0",
                    ],
                    "instructions": "Provides one read-only Codex workspace runtime locator.",
                ],
            ])
        case "ping":
            return encode(["jsonrpc": "2.0", "id": id, "result": [:]])
        case "tools/list":
            return encode([
                "jsonrpc": "2.0",
                "id": id,
                "result": ["tools": [toolDefinition]],
            ])
        case "tools/call":
            let params = message["params"] as? [String: Any]
            guard params?["name"] as? String == "load_workspace_dependencies" else {
                return encode(errorResponse(
                    id: id, code: -32602, message: "Unknown tool"))
            }
            do {
                let runtime = try WorkspaceDependenciesRuntime.load(
                    from: runtimeRoot ?? defaultRuntimeRoot(
                        environment: environment,
                        homeDirectory: homeDirectory),
                    fileManager: fileManager)
                return encode([
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": [
                        "content": [["type": "text", "text": runtime.toolResult]],
                        "isError": false,
                    ],
                ])
            } catch {
                return encode([
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": [
                        "content": [[
                            "type": "text",
                            "text": "The bundled Codex workspace runtime is unavailable.",
                        ]],
                        "isError": true,
                    ],
                ])
            }
        default:
            return encode(errorResponse(
                id: id, code: -32601, message: "Method not found"))
        }
    }

    private static let toolDefinition: [String: Any] = [
        "name": "load_workspace_dependencies",
        "description": "Locate validated bundled Codex workspace dependency runtime paths. This is read-only and takes no arguments.",
        "inputSchema": [
            "type": "object",
            "properties": [:],
            "additionalProperties": false,
        ],
    ]

    private static func defaultRuntimeRoot(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        let cacheRoot: URL
        if let configured = environment["XDG_CACHE_HOME"],
           configured.hasPrefix("/") {
            cacheRoot = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            cacheRoot = homeDirectory.appendingPathComponent(
                ".cache", isDirectory: true)
        }
        return cacheRoot
            .appendingPathComponent("codex-runtimes", isDirectory: true)
            .appendingPathComponent("codex-primary-runtime", isDirectory: true)
    }

    private static func errorResponse(
        id: Any,
        code: Int,
        message: String
    ) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ]
    }

    private static func encode(_ object: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
