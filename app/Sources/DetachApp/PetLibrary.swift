import Foundation
import ImageIO

struct PetManifest: Decodable, Equatable {
    let id: String
    let displayName: String
    let description: String
    let spriteVersionNumber: Int?
    let spritesheetPath: String
}

struct PetPackage: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let description: String
    let spriteVersionNumber: Int
    let spritesheetURL: URL
    let directoryURL: URL

    var rows: Int { spriteVersionNumber == 2 ? 11 : 9 }
}

struct PetPackageIssue: Equatable, Sendable {
    let packageName: String
    let reason: String
}

struct PetLibraryResult: Equatable, Sendable {
    let packages: [PetPackage]
    let issues: [PetPackageIssue]
}

enum PetLibraryLoader {
    static let cellWidth = 192
    static let cellHeight = 208
    static let columns = 8
    static let maximumManifestBytes = 64 * 1_024
    static let maximumSpritesheetBytes = 20 * 1_024 * 1_024
    static let maximumPackages = 128

    static func defaultRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        let codexRoot: URL
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            codexRoot = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            codexRoot = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return codexRoot.appendingPathComponent("pets", isDirectory: true)
    }

    static func bundledRoot(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let root = resourceURL.appendingPathComponent("Pets", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return root
    }

    static func load(
        userRoot: URL,
        bundledRoot: URL?,
        fileManager: FileManager = .default
    ) -> PetLibraryResult {
        let user = load(from: userRoot, fileManager: fileManager)
        guard let bundledRoot,
              bundledRoot.standardizedFileURL != userRoot.standardizedFileURL else {
            return user
        }

        let bundled = load(from: bundledRoot, fileManager: fileManager)
        var identifiers = Set(user.packages.map(\.id))
        let fallbackPackages = bundled.packages.filter {
            identifiers.insert($0.id).inserted
        }
        return PetLibraryResult(
            packages: (user.packages + fallbackPackages).sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            },
            issues: user.issues + bundled.issues)
    }

    static func load(
        from root: URL,
        fileManager: FileManager = .default
    ) -> PetLibraryResult {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else {
            return PetLibraryResult(packages: [], issues: [])
        }

        var packages: [PetPackage] = []
        var issues: [PetPackageIssue] = []
        var identifiers: Set<String> = []
        for directory in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .prefix(maximumPackages) {
            let packageName = directory.lastPathComponent
            do {
                let values = try directory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    continue
                }
                let package = try loadPackage(
                    from: directory,
                    fileManager: fileManager)
                guard identifiers.insert(package.id).inserted else {
                    throw PetLibraryError("duplicate pet id \(package.id)")
                }
                packages.append(package)
            } catch {
                issues.append(PetPackageIssue(
                    packageName: packageName,
                    reason: error.localizedDescription))
            }
        }

        return PetLibraryResult(
            packages: packages.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            },
            issues: issues)
    }

    static func loadPackage(
        from directory: URL,
        fileManager: FileManager
    ) throws -> PetPackage {
        let directoryValues = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw PetLibraryError("pet package must be a regular directory")
        }
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let manifestURL = directory.appendingPathComponent("pet.json")
        let manifestValues = try manifestURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard manifestValues.isRegularFile == true,
              manifestValues.isSymbolicLink != true else {
            throw PetLibraryError("pet.json must be a regular file")
        }
        guard (manifestValues.fileSize ?? maximumManifestBytes + 1)
                <= maximumManifestBytes else {
            throw PetLibraryError("pet.json is too large")
        }
        let manifest = try JSONDecoder().decode(
            PetManifest.self,
            from: Data(contentsOf: manifestURL, options: [.mappedIfSafe]))
        try validateIdentifier(manifest.id)
        guard !manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PetLibraryError("displayName is empty")
        }

        let version = manifest.spriteVersionNumber ?? 1
        guard version == 1 || version == 2 else {
            throw PetLibraryError("unsupported spriteVersionNumber \(version)")
        }
        let relativePath = manifest.spritesheetPath
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            throw PetLibraryError("spritesheetPath must stay inside the pet package")
        }

        let lexicalSprite = directory.appendingPathComponent(relativePath)
            .standardizedFileURL
        guard isDescendant(lexicalSprite, of: directory.standardizedFileURL) else {
            throw PetLibraryError("spritesheetPath escapes the pet package")
        }
        let lexicalValues = try lexicalSprite.resourceValues(
            forKeys: [.isSymbolicLinkKey])
        guard lexicalValues.isSymbolicLink != true else {
            throw PetLibraryError("spritesheetPath cannot be a symbolic link")
        }
        let spriteURL = lexicalSprite.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(spriteURL, of: resolvedDirectory) else {
            throw PetLibraryError("spritesheetPath resolves outside the pet package")
        }
        let spriteValues = try spriteURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard spriteValues.isRegularFile == true,
              spriteValues.isSymbolicLink != true else {
            throw PetLibraryError("spritesheet must be a regular file")
        }
        guard (spriteValues.fileSize ?? maximumSpritesheetBytes + 1)
                <= maximumSpritesheetBytes else {
            throw PetLibraryError("spritesheet is larger than 20 MiB")
        }
        guard ["png", "webp"].contains(spriteURL.pathExtension.lowercased()) else {
            throw PetLibraryError("spritesheet must be PNG or WebP")
        }

        let dimensions = try imageDimensions(at: spriteURL)
        let expected = (width: cellWidth * columns,
                        height: cellHeight * (version == 2 ? 11 : 9))
        guard dimensions == expected else {
            throw PetLibraryError(
                "spritesheet must be \(expected.width)×\(expected.height) pixels")
        }

        return PetPackage(
            id: manifest.id,
            displayName: manifest.displayName,
            description: manifest.description,
            spriteVersionNumber: version,
            spritesheetURL: spriteURL,
            directoryURL: resolvedDirectory)
    }

    private static func validateIdentifier(_ identifier: String) throws {
        guard !identifier.isEmpty,
              identifier.utf8.count <= 100,
              !identifier.contains("/"),
              !identifier.contains("\\"),
              identifier.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw PetLibraryError("pet id is invalid")
        }
    }

    private static func imageDimensions(at url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw PetLibraryError("spritesheet could not be decoded")
        }
        return (width.intValue, height.intValue)
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return childPath.hasPrefix(parentPath + "/")
    }
}

enum PetLibraryInstaller {
    static func install(
        from source: URL,
        into root: URL,
        fileManager: FileManager = .default
    ) throws -> PetPackage {
        let source = source.standardizedFileURL
        let root = root.standardizedFileURL
        let sourcePackage = try PetLibraryLoader.loadPackage(
            from: source,
            fileManager: fileManager)

        if source.deletingLastPathComponent().standardizedFileURL == root {
            return sourcePackage
        }
        guard root != source, !isDescendant(root, of: source) else {
            throw PetLibraryInstallError(
                "the pets library cannot be inside the selected package")
        }

        let existing = PetLibraryLoader.load(from: root, fileManager: fileManager)
        guard !existing.packages.contains(where: { $0.id == sourcePackage.id }) else {
            throw PetLibraryInstallError(
                "a pet with id \(sourcePackage.id) is already installed")
        }
        let currentEntryCount = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]))?.count ?? 0
        guard currentEntryCount < PetLibraryLoader.maximumPackages else {
            throw PetLibraryInstallError(
                "the pets library already contains the maximum number of packages")
        }

        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(
            ".pet-import-\(UUID().uuidString)",
            isDirectory: true)
        var installedURL: URL?
        do {
            try copyRequiredFiles(
                from: sourcePackage,
                to: staging,
                fileManager: fileManager)
            let stagedPackage = try PetLibraryLoader.loadPackage(
                from: staging,
                fileManager: fileManager)
            guard stagedPackage.id == sourcePackage.id else {
                throw PetLibraryInstallError(
                    "the copied package identity does not match the selected package")
            }

            let destination = availableDestination(
                for: source,
                packageID: sourcePackage.id,
                in: root,
                fileManager: fileManager)
            try fileManager.moveItem(at: staging, to: destination)
            installedURL = destination
            return try PetLibraryLoader.loadPackage(
                from: destination,
                fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: staging)
            if let installedURL {
                try? fileManager.removeItem(at: installedURL)
            }
            throw error
        }
    }

    private static func copyRequiredFiles(
        from package: PetPackage,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: false)
        try fileManager.copyItem(
            at: package.directoryURL.appendingPathComponent("pet.json"),
            to: destination.appendingPathComponent("pet.json"))

        let packagePath = package.directoryURL.standardizedFileURL.path + "/"
        let spritePath = package.spritesheetURL.standardizedFileURL.path
        guard spritePath.hasPrefix(packagePath) else {
            throw PetLibraryInstallError(
                "the spritesheet is outside the selected package")
        }
        let relativeSpritePath = String(spritePath.dropFirst(packagePath.count))
        let destinationSprite = destination.appendingPathComponent(
            relativeSpritePath)
        try fileManager.createDirectory(
            at: destinationSprite.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: package.spritesheetURL,
            to: destinationSprite)
    }

    private static func availableDestination(
        for source: URL,
        packageID: String,
        in root: URL,
        fileManager: FileManager
    ) -> URL {
        var baseName = source.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if baseName.isEmpty || baseName.hasPrefix(".") {
            baseName = packageID.replacingOccurrences(of: "/", with: "-")
        }
        if baseName.isEmpty || baseName.hasPrefix(".") {
            baseName = "pet"
        }

        var candidate = root.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent(
                "\(baseName)-\(suffix)",
                isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        child.standardizedFileURL.path.hasPrefix(
            parent.standardizedFileURL.path + "/")
    }
}

private struct PetLibraryError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct PetLibraryInstallError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
