import AppKit
import DetachKit
import ImageIO

enum PetAnimationState: CaseIterable {
    case idle
    case runningRight
    case runningLeft
    case waving
    case jumping
    case failed
    case waiting
    case running
    case review

    var row: Int {
        switch self {
        case .idle: 0
        case .runningRight: 1
        case .runningLeft: 2
        case .waving: 3
        case .jumping: 4
        case .failed: 5
        case .waiting: 6
        case .running: 7
        case .review: 8
        }
    }

    var frameDurations: [TimeInterval] {
        switch self {
        case .idle: [0.280, 0.110, 0.110, 0.140, 0.140, 0.320]
        case .runningRight, .runningLeft:
            Array(repeating: 0.120, count: 7) + [0.220]
        case .waving:
            Array(repeating: 0.140, count: 3) + [0.280]
        case .jumping:
            Array(repeating: 0.140, count: 4) + [0.280]
        case .failed:
            Array(repeating: 0.140, count: 7) + [0.240]
        case .waiting:
            Array(repeating: 0.150, count: 5) + [0.260]
        case .running:
            Array(repeating: 0.120, count: 5) + [0.220]
        case .review:
            Array(repeating: 0.150, count: 5) + [0.280]
        }
    }

    static func state(for activity: PetActivityState?) -> PetAnimationState {
        switch activity {
        case .needsInput: .waiting
        case .blocked: .failed
        case .ready: .review
        case .running: .running
        case nil: .idle
        }
    }
}

struct PetAtlasFrame: Equatable {
    let row: Int
    let column: Int
}

enum PetAnimationFrameResolver {
    static let pointerDeadzone: CGFloat = 28

    static func frame(
        activity: PetActivityState?,
        elapsed: TimeInterval,
        reduceMotion: Bool,
        pointerVector: CGVector?,
        supportsLookDirections: Bool
    ) -> PetAtlasFrame {
        if activity == nil,
           supportsLookDirections,
           let direction = lookDirection(for: pointerVector) {
            return PetAtlasFrame(
                row: direction < 8 ? 9 : 10,
                column: direction % 8)
        }

        // Several compatible pet atlases use a fairly energetic idle row.
        // A neutral still frame makes "nothing needs attention" visually
        // distinct from work and answer-ready animations.
        if activity == nil {
            return PetAtlasFrame(row: PetAnimationState.idle.row, column: 0)
        }

        let state = PetAnimationState.state(for: activity)
        guard !reduceMotion else {
            return PetAtlasFrame(row: state.row, column: 0)
        }
        let durations = state.frameDurations
        let total = durations.reduce(0, +)
        var remaining = elapsed.truncatingRemainder(dividingBy: total)
        if remaining < 0 { remaining += total }
        for (index, duration) in durations.enumerated() {
            if remaining < duration {
                return PetAtlasFrame(row: state.row, column: index)
            }
            remaining -= duration
        }
        return PetAtlasFrame(row: state.row, column: durations.count - 1)
    }

    /// Codex v2 directions run clockwise with 000 at screen-up.
    static func lookDirection(for vector: CGVector?) -> Int? {
        guard let vector,
              hypot(vector.dx, vector.dy) >= pointerDeadzone else { return nil }
        var angle = atan2(vector.dx, vector.dy)
        if angle < 0 { angle += 2 * .pi }
        return Int((angle / (2 * .pi) * 16).rounded()) % 16
    }
}

@MainActor
final class PetAtlas {
    let package: PetPackage
    private let image: CGImage
    private var cache: [Int: NSImage] = [:]

    init(package: PetPackage) throws {
        guard let source = CGImageSourceCreateWithURL(
            package.spritesheetURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PetAtlasError("The pet spritesheet could not be decoded.")
        }
        self.package = package
        self.image = image
    }

    func frame(_ frame: PetAtlasFrame) -> NSImage? {
        guard (0..<package.rows).contains(frame.row),
              (0..<PetLibraryLoader.columns).contains(frame.column) else {
            return nil
        }
        let key = frame.row * PetLibraryLoader.columns + frame.column
        if let cached = cache[key] { return cached }
        let rect = CGRect(
            x: frame.column * PetLibraryLoader.cellWidth,
            y: frame.row * PetLibraryLoader.cellHeight,
            width: PetLibraryLoader.cellWidth,
            height: PetLibraryLoader.cellHeight)
        guard let cropped = image.cropping(to: rect) else { return nil }
        let result = NSImage(
            cgImage: cropped,
            size: NSSize(
                width: PetLibraryLoader.cellWidth,
                height: PetLibraryLoader.cellHeight))
        cache[key] = result
        return result
    }
}

private struct PetAtlasError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
