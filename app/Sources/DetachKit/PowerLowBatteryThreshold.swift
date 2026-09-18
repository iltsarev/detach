import Foundation

/// Conservative battery floor for releasing Detach-owned sleep protection.
///
/// The helper never accepts a value below 10%. A missing or unknown stored
/// value becomes the default floor so a damaged document cannot disable the
/// fail-safe.
public enum PowerLowBatteryThreshold: Int, Codable, CaseIterable, Sendable {
    case percent10 = 10
    case percent15 = 15
    case percent20 = 20

    public static let minimum = Self.percent10
    public static let `default` = Self.percent10

    public static func parse(_ raw: Int?) -> Self {
        raw.flatMap(Self.init(rawValue:)) ?? .default
    }
}
