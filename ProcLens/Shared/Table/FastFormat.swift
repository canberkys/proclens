import Foundation

/// Integer-math formatters for per-cell, per-tick use (no `String(format:)`, no `ByteCountFormatter`).
enum FastFormat {
    /// 0.1 resolution, "12.3%".
    static func percent(_ fraction: Double) -> String {
        let t = Int((max(0, fraction) * 1000).rounded())
        return "\(t / 10).\(t % 10)%"
    }

    /// "812.4 MB" / "1.2 GB" (binary units, like Task Manager).
    static func bytes(_ value: UInt64) -> String {
        let v = Double(value)
        switch v {
        case ..<1_024: return "\(value) B"
        case ..<1_048_576: return tenths(v / 1_024) + " KB"
        case ..<1_073_741_824: return tenths(v / 1_048_576) + " MB"
        default: return tenths(v / 1_073_741_824) + " GB"
        }
    }

    /// "0 MB/s" for idle, otherwise like `bytes` + "/s".
    static func rate(_ bytesPerSec: Double) -> String {
        guard bytesPerSec >= 1 else { return "0 MB/s" }
        return bytes(UInt64(bytesPerSec)) + "/s"
    }

    private static func tenths(_ x: Double) -> String {
        let t = Int((x * 10).rounded())
        return "\(t / 10).\(t % 10)"
    }
}
