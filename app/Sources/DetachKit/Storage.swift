import Darwin
import Foundation

public enum StorageIssueSeverity: String, Codable, Sendable {
    case warning
    case error
}

public struct StorageIssue: Codable, Equatable, Sendable {
    public var severity: StorageIssueSeverity
    public var code: String
    public var path: String

    public init(severity: StorageIssueSeverity, code: String, path: String) {
        self.severity = severity
        self.code = code
        self.path = path
    }
}

public struct StorageCategories: Codable, Equatable, Sendable {
    public var sessionDataBytes: UInt64
    public var checkpointBytes: UInt64
    public var logBytes: UInt64
    public var otherStateBytes: UInt64

    public init(
        sessionDataBytes: UInt64 = 0,
        checkpointBytes: UInt64 = 0,
        logBytes: UInt64 = 0,
        otherStateBytes: UInt64 = 0
    ) {
        self.sessionDataBytes = sessionDataBytes
        self.checkpointBytes = checkpointBytes
        self.logBytes = logBytes
        self.otherStateBytes = otherStateBytes
    }

    public var totalBytes: UInt64 {
        [sessionDataBytes, checkpointBytes, logBytes, otherStateBytes]
            .reduce(0, Self.saturatingAdd)
    }

    fileprivate mutating func add(_ bytes: UInt64, category: StorageCategory) {
        switch category {
        case .sessionData:
            sessionDataBytes = Self.saturatingAdd(sessionDataBytes, bytes)
        case .checkpoint:
            checkpointBytes = Self.saturatingAdd(checkpointBytes, bytes)
        case .log:
            logBytes = Self.saturatingAdd(logBytes, bytes)
        case .otherState:
            otherStateBytes = Self.saturatingAdd(otherStateBytes, bytes)
        }
    }

    fileprivate mutating func merge(_ other: StorageCategories) {
        sessionDataBytes = Self.saturatingAdd(sessionDataBytes, other.sessionDataBytes)
        checkpointBytes = Self.saturatingAdd(checkpointBytes, other.checkpointBytes)
        logBytes = Self.saturatingAdd(logBytes, other.logBytes)
        otherStateBytes = Self.saturatingAdd(otherStateBytes, other.otherStateBytes)
    }

    private static func saturatingAdd(_ left: UInt64, _ right: UInt64) -> UInt64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? .max : value
    }

    enum CodingKeys: String, CodingKey {
        case sessionDataBytes = "session_data_bytes"
        case checkpointBytes = "checkpoint_bytes"
        case logBytes = "log_bytes"
        case otherStateBytes = "other_state_bytes"
    }
}

public struct StorageSession: Codable, Equatable, Sendable, Identifiable {
    public var provider: Provider
    public var sessionName: String
    public var effectiveStatus: EffectiveStatus
    public var path: String
    public var allocatedBytes: UInt64
    public var logicalBytes: UInt64
    public var categories: StorageCategories
    public var scanComplete: Bool
    public var symlinkCount: Int
    public var hardLinkCount: Int
    public var deletable: Bool
    public var blockedReason: String?

    public var id: String { "\(provider.rawValue):\(sessionName)" }

    enum CodingKeys: String, CodingKey {
        case provider, path, categories, deletable
        case sessionName = "session_name"
        case effectiveStatus = "effective_status"
        case allocatedBytes = "allocated_bytes"
        case logicalBytes = "logical_bytes"
        case scanComplete = "scan_complete"
        case symlinkCount = "symlink_count"
        case hardLinkCount = "hard_link_count"
        case blockedReason = "blocked_reason"
    }
}

public struct StorageReport: Codable, Equatable, Sendable {
    public var schema: Int
    public var stateRoot: String
    public var complete: Bool
    public var allocatedBytes: UInt64
    public var logicalBytes: UInt64
    public var categories: StorageCategories
    public var sessions: [StorageSession]
    public var issues: [StorageIssue]

    public init(
        schema: Int = 1,
        stateRoot: String,
        complete: Bool,
        allocatedBytes: UInt64,
        logicalBytes: UInt64,
        categories: StorageCategories,
        sessions: [StorageSession],
        issues: [StorageIssue]
    ) {
        self.schema = schema
        self.stateRoot = stateRoot
        self.complete = complete
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.categories = categories
        self.sessions = sessions
        self.issues = issues
    }

    enum CodingKeys: String, CodingKey {
        case schema, complete, categories, sessions, issues
        case stateRoot = "state_root"
        case allocatedBytes = "allocated_bytes"
        case logicalBytes = "logical_bytes"
    }
}

public struct StorageCleanupPlan: Codable, Equatable, Sendable {
    public var schema: Int
    public var dryRun: Bool
    public var reportComplete: Bool
    public var allocatedBytes: UInt64
    public var logicalBytes: UInt64
    public var sessions: [StorageSession]

    enum CodingKeys: String, CodingKey {
        case schema, sessions
        case dryRun = "dry_run"
        case reportComplete = "report_complete"
        case allocatedBytes = "allocated_bytes"
        case logicalBytes = "logical_bytes"
    }
}

enum StorageInspectionError: Error, Equatable {
    case invalidArguments
    case invalidInventory
    case invalidReport
    case unsafeSelection(String)
}

enum StorageInspector {
    static func report(
        stateRoot: String,
        providerRoots: [Provider: String],
        excludedRoots: [String],
        inventory: Data
    ) throws -> StorageReport {
        let parsed = SessionListParser.parse(String(decoding: inventory, as: UTF8.self))
        guard !parsed.hadInvalidLines else { throw StorageInspectionError.invalidInventory }
        let statuses = Dictionary(
            parsed.sessions.map { (SessionKey(provider: $0.provider, name: $0.sessionName), $0.effectiveStatus) },
            uniquingKeysWith: { _, latest in latest })
        var scanner = StorageScanner(
            stateRoot: stateRoot,
            providerRoots: providerRoots,
            excludedRoots: excludedRoots,
            statuses: statuses)
        return scanner.scan()
    }

    static func cleanupPlan(
        reportData: Data,
        selectAll: Bool,
        sessionNames: [String]
    ) throws -> StorageCleanupPlan {
        let decoder = JSONDecoder()
        guard let report = try? decoder.decode(StorageReport.self, from: reportData),
              report.schema == 1,
              selectAll != !sessionNames.isEmpty else {
            throw StorageInspectionError.invalidReport
        }
        let selected: [StorageSession]
        if selectAll {
            selected = report.sessions.filter(\.deletable)
        } else {
            var remaining = Set(sessionNames)
            selected = try report.sessions.compactMap { session in
                guard remaining.remove(session.sessionName) != nil else { return nil }
                guard session.deletable else {
                    throw StorageInspectionError.unsafeSelection(session.sessionName)
                }
                return session
            }
            if let missing = remaining.sorted().first {
                throw StorageInspectionError.unsafeSelection(missing)
            }
        }
        return StorageCleanupPlan(
            schema: 1,
            dryRun: true,
            reportComplete: report.complete,
            allocatedBytes: selected.reduce(0) { saturatingAdd($0, $1.allocatedBytes) },
            logicalBytes: selected.reduce(0) { saturatingAdd($0, $1.logicalBytes) },
            sessions: selected.sorted { $0.allocatedBytes > $1.allocatedBytes })
    }
}

private struct SessionKey: Hashable {
    var provider: Provider
    var name: String
}

private enum StorageCategory {
    case sessionData
    case checkpoint
    case log
    case otherState
}

private struct FileIdentity: Hashable {
    var device: UInt64
    var inode: UInt64
}

private struct ScanMetrics {
    var allocatedBytes: UInt64 = 0
    var logicalBytes: UInt64 = 0
    var categories = StorageCategories()
    var issues: [StorageIssue] = []
    var symlinkCount = 0
    var hardLinkCount = 0

    var complete: Bool {
        !issues.contains { $0.severity == .error }
    }

    mutating func add(metadata: stat, category: StorageCategory, countAllocated: Bool = true) {
        let allocated = countAllocated && metadata.st_blocks > 0
            ? saturatingMultiply(UInt64(metadata.st_blocks), 512) : 0
        let logical = metadata.st_size > 0 ? UInt64(metadata.st_size) : 0
        allocatedBytes = saturatingAdd(allocatedBytes, allocated)
        logicalBytes = saturatingAdd(logicalBytes, logical)
        categories.add(allocated, category: category)
    }

    mutating func merge(_ other: ScanMetrics) {
        allocatedBytes = saturatingAdd(allocatedBytes, other.allocatedBytes)
        logicalBytes = saturatingAdd(logicalBytes, other.logicalBytes)
        categories.merge(other.categories)
        issues.append(contentsOf: other.issues)
        symlinkCount += other.symlinkCount
        hardLinkCount += other.hardLinkCount
    }
}

private struct StorageScanner {
    let stateRoot: String
    let providerRoots: [Provider: String]
    let excludedRoots: [String]
    let statuses: [SessionKey: EffectiveStatus]
    let fileManager = FileManager.default
    let ownerUID = getuid()
    var seenFiles = Set<FileIdentity>()

    mutating func scan() -> StorageReport {
        let normalizedStateRoot = normalized(stateRoot)
        let normalizedExcluded = excludedRoots.map(normalized)
        let normalizedProviderRoots = providerRoots.mapValues(normalized)
        let sessionRoots = normalizedProviderRoots.mapValues { "\($0)/sessions" }
        var sessions: [StorageSession] = []
        var issues: [StorageIssue] = []
        var scannedPaths = Set<String>()

        for provider in Provider.allCases {
            guard let providerRoot = normalizedProviderRoots[provider],
                  let sessionsRoot = sessionRoots[provider],
                  scannedPaths.insert(sessionsRoot).inserted else {
                continue
            }
            if normalizedExcluded.contains(where: {
                contains(sessionsRoot, root: $0) || contains($0, root: sessionsRoot)
            }) {
                issues.append(StorageIssue(
                    severity: .error,
                    code: "sessions_root_overlaps_excluded_storage",
                    path: sessionsRoot))
                continue
            }
            guard let providerMetadata = metadata(at: providerRoot) else {
                if fileManager.fileExists(atPath: providerRoot) {
                    issues.append(StorageIssue(
                        severity: .error,
                        code: "provider_state_root_unreadable",
                        path: providerRoot))
                }
                continue
            }
            guard isDirectory(providerMetadata),
                  !isSymbolicLink(providerMetadata),
                  providerMetadata.st_uid == ownerUID else {
                issues.append(StorageIssue(
                    severity: .error,
                    code: "provider_state_root_unsafe",
                    path: providerRoot))
                continue
            }
            let result = scanSessionsRoot(sessionsRoot, provider: provider)
            sessions.append(contentsOf: result.sessions)
            issues.append(contentsOf: result.issues)
        }

        let excluded = Set(sessionRoots.values).union(normalizedExcluded)
        let other = if normalizedExcluded.contains(where: {
            contains(normalizedStateRoot, root: $0)
        }) {
            errorMetrics(code: "state_root_overlaps_excluded_storage", path: normalizedStateRoot)
        } else {
            scanOtherStateRoot(normalizedStateRoot, excludedRoots: excluded)
        }
        issues.append(contentsOf: other.issues)
        var categories = other.categories
        var allocated = other.allocatedBytes
        var logical = other.logicalBytes
        for session in sessions {
            categories.merge(session.categories)
            allocated = saturatingAdd(allocated, session.allocatedBytes)
            logical = saturatingAdd(logical, session.logicalBytes)
        }
        sessions.sort {
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            return $0.sessionName < $1.sessionName
        }
        return StorageReport(
            stateRoot: normalizedStateRoot,
            complete: !issues.contains { $0.severity == .error },
            allocatedBytes: allocated,
            logicalBytes: logical,
            categories: categories,
            sessions: sessions,
            issues: issues.sorted { ($0.path, $0.code) < ($1.path, $1.code) })
    }

    private mutating func scanSessionsRoot(
        _ root: String,
        provider: Provider
    ) -> (sessions: [StorageSession], issues: [StorageIssue]) {
        guard let rootMetadata = metadata(at: root) else {
            return fileManager.fileExists(atPath: root)
                ? ([], [StorageIssue(severity: .error, code: "sessions_root_unreadable", path: root)])
                : ([], [])
        }
        guard isDirectory(rootMetadata), !isSymbolicLink(rootMetadata), rootMetadata.st_uid == ownerUID else {
            return ([], [StorageIssue(severity: .error, code: "sessions_root_unsafe", path: root)])
        }
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: root).sorted()
        } catch {
            return ([], [StorageIssue(severity: .error, code: "sessions_root_unreadable", path: root)])
        }
        var sessions: [StorageSession] = []
        var issues: [StorageIssue] = []
        let prefix = "detach-\(provider.rawValue)-"
        for name in names {
            let path = "\(root)/\(name)"
            guard name.hasPrefix(prefix), let status = statuses[SessionKey(provider: provider, name: name)] else {
                issues.append(StorageIssue(severity: .error, code: "unowned_session_entry", path: path))
                continue
            }
            guard let directoryMetadata = metadata(at: path),
                  isDirectory(directoryMetadata),
                  !isSymbolicLink(directoryMetadata),
                  directoryMetadata.st_uid == ownerUID else {
                issues.append(StorageIssue(severity: .error, code: "session_directory_unsafe", path: path))
                sessions.append(blockedSession(
                    provider: provider, name: name, status: status, path: path,
                    reason: "unsafe_directory"))
                continue
            }
            guard validMetadata(in: path, provider: provider, sessionName: name) else {
                issues.append(StorageIssue(severity: .error, code: "session_metadata_invalid", path: path))
                sessions.append(blockedSession(
                    provider: provider, name: name, status: status, path: path,
                    reason: "invalid_metadata"))
                continue
            }
            let metrics = walk(path: path, relativeComponents: [])
            let statusAllowsDeletion = status == .stopped || status == .orphaned
            let deletable = metrics.complete && metrics.hardLinkCount == 0 && statusAllowsDeletion
            let reason: String? = if !metrics.complete {
                "incomplete_scan"
            } else if metrics.hardLinkCount > 0 {
                "hard_links"
            } else if !statusAllowsDeletion {
                "status_\(status.rawValue)"
            } else {
                nil
            }
            issues.append(contentsOf: metrics.issues)
            sessions.append(StorageSession(
                provider: provider,
                sessionName: name,
                effectiveStatus: status,
                path: path,
                allocatedBytes: metrics.allocatedBytes,
                logicalBytes: metrics.logicalBytes,
                categories: metrics.categories,
                scanComplete: metrics.complete,
                symlinkCount: metrics.symlinkCount,
                hardLinkCount: metrics.hardLinkCount,
                deletable: deletable,
                blockedReason: reason))
        }
        return (sessions, issues)
    }

    private func blockedSession(
        provider: Provider,
        name: String,
        status: EffectiveStatus,
        path: String,
        reason: String
    ) -> StorageSession {
        StorageSession(
            provider: provider, sessionName: name, effectiveStatus: status, path: path,
            allocatedBytes: 0, logicalBytes: 0, categories: StorageCategories(),
            scanComplete: false, symlinkCount: 0, hardLinkCount: 0,
            deletable: false, blockedReason: reason)
    }

    private mutating func scanOtherStateRoot(
        _ root: String,
        excludedRoots: Set<String>
    ) -> ScanMetrics {
        guard !excludedRoots.contains(root) else {
            var metrics = ScanMetrics()
            metrics.issues.append(StorageIssue(
                severity: .error, code: "state_root_overlaps_excluded_storage", path: root))
            return metrics
        }
        guard let rootMetadata = metadata(at: root) else {
            return fileManager.fileExists(atPath: root)
                ? errorMetrics(code: "state_root_unreadable", path: root)
                : ScanMetrics()
        }
        guard isDirectory(rootMetadata), !isSymbolicLink(rootMetadata), rootMetadata.st_uid == ownerUID else {
            return errorMetrics(code: "state_root_unsafe", path: root)
        }
        return walkOther(path: root, excludedRoots: excludedRoots)
    }

    private mutating func walkOther(path: String, excludedRoots: Set<String>) -> ScanMetrics {
        if excludedRoots.contains(normalized(path)) { return ScanMetrics() }
        guard let item = metadata(at: path) else {
            return errorMetrics(code: "entry_unreadable", path: path)
        }
        var metrics = ScanMetrics()
        if isSymbolicLink(item) {
            metrics.add(metadata: item, category: .otherState)
            metrics.symlinkCount = 1
            return metrics
        }
        if item.st_uid != ownerUID {
            metrics.issues.append(StorageIssue(severity: .error, code: "foreign_owner", path: path))
            return metrics
        }
        if isRegularFile(item) {
            addFile(item, to: &metrics, category: .otherState)
            return metrics
        }
        guard isDirectory(item) else {
            metrics.add(metadata: item, category: .otherState)
            metrics.issues.append(StorageIssue(severity: .warning, code: "special_entry", path: path))
            return metrics
        }
        metrics.add(metadata: item, category: .otherState)
        do {
            for child in try fileManager.contentsOfDirectory(atPath: path).sorted() {
                metrics.merge(walkOther(path: "\(path)/\(child)", excludedRoots: excludedRoots))
            }
        } catch {
            metrics.issues.append(StorageIssue(severity: .error, code: "directory_unreadable", path: path))
        }
        return metrics
    }

    private mutating func walk(path: String, relativeComponents: [String]) -> ScanMetrics {
        guard let item = metadata(at: path) else {
            return errorMetrics(code: "entry_unreadable", path: path)
        }
        let category = category(for: relativeComponents)
        var metrics = ScanMetrics()
        if isSymbolicLink(item) {
            metrics.add(metadata: item, category: category)
            metrics.symlinkCount = 1
            return metrics
        }
        guard item.st_uid == ownerUID else {
            metrics.issues.append(StorageIssue(severity: .error, code: "foreign_owner", path: path))
            return metrics
        }
        if isRegularFile(item) {
            addFile(item, to: &metrics, category: category)
            return metrics
        }
        guard isDirectory(item) else {
            metrics.add(metadata: item, category: category)
            metrics.issues.append(StorageIssue(severity: .error, code: "special_session_entry", path: path))
            return metrics
        }
        metrics.add(metadata: item, category: category)
        do {
            for child in try fileManager.contentsOfDirectory(atPath: path).sorted() {
                metrics.merge(walk(
                    path: "\(path)/\(child)",
                    relativeComponents: relativeComponents + [child]))
            }
        } catch {
            metrics.issues.append(StorageIssue(severity: .error, code: "directory_unreadable", path: path))
        }
        return metrics
    }

    private mutating func addFile(
        _ item: stat,
        to metrics: inout ScanMetrics,
        category: StorageCategory
    ) {
        let identity = FileIdentity(device: UInt64(item.st_dev), inode: UInt64(item.st_ino))
        let isHardLink = item.st_nlink > 1
        let firstReference = seenFiles.insert(identity).inserted
        metrics.add(metadata: item, category: category, countAllocated: firstReference)
        if isHardLink { metrics.hardLinkCount += 1 }
    }

    private func category(for components: [String]) -> StorageCategory {
        guard let first = components.first else { return .sessionData }
        if first == "checkpoint.log" { return .log }
        guard first == "checkpoint" else { return .sessionData }
        guard components.count > 1 else { return .checkpoint }
        let name = components[1]
        return name == "pane.txt" || name == "pane-ansi.txt" ? .log : .checkpoint
    }

    private func validMetadata(in sessionPath: String, provider: Provider, sessionName: String) -> Bool {
        for path in ["\(sessionPath)/meta.json", "\(sessionPath)/checkpoint/meta.json"] {
            guard let data = readOwnedRegularFile(path, maximumBytes: 1_048_576),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["schema"] as? Int == 1,
                  object["session_name"] as? String == sessionName else { continue }
            let metadataProvider = (object["provider"] as? String) ?? "codex"
            if metadataProvider == provider.rawValue { return true }
        }
        return false
    }

    private func readOwnedRegularFile(_ path: String, maximumBytes: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var item = stat()
        guard fstat(descriptor, &item) == 0,
              isRegularFile(item),
              item.st_uid == ownerUID,
              item.st_size >= 0,
              item.st_size <= maximumBytes else { return nil }
        var data = Data(count: Int(item.st_size))
        let readSucceeded = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return item.st_size == 0 }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if count == 0 { return false }
                offset += count
            }
            return true
        }
        return readSucceeded ? data : nil
    }

    private func metadata(at path: String) -> stat? {
        var item = stat()
        return lstat(path, &item) == 0 ? item : nil
    }

    private func isDirectory(_ item: stat) -> Bool { item.st_mode & S_IFMT == S_IFDIR }
    private func isRegularFile(_ item: stat) -> Bool { item.st_mode & S_IFMT == S_IFREG }
    private func isSymbolicLink(_ item: stat) -> Bool { item.st_mode & S_IFMT == S_IFLNK }

    private func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func contains(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private func errorMetrics(code: String, path: String) -> ScanMetrics {
        var metrics = ScanMetrics()
        metrics.issues.append(StorageIssue(severity: .error, code: code, path: path))
        return metrics
    }
}

private func saturatingAdd(_ left: UInt64, _ right: UInt64) -> UInt64 {
    let (value, overflow) = left.addingReportingOverflow(right)
    return overflow ? .max : value
}

private func saturatingMultiply(_ left: UInt64, _ right: UInt64) -> UInt64 {
    let (value, overflow) = left.multipliedReportingOverflow(by: right)
    return overflow ? .max : value
}
