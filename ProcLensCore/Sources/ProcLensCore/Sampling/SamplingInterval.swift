/// User-selectable refresh rate; the raw value is seconds.
public enum SamplingInterval: Double, CaseIterable, Sendable {
    case halfSecond = 0.5
    case oneSecond = 1
    case twoSeconds = 2
    case fiveSeconds = 5

    public static let `default`: SamplingInterval = .oneSecond

    public var duration: Duration { .seconds(rawValue) }
}
