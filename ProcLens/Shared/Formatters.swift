import Foundation

/// Display formatting shared by all tabs. Kept allocation-light: called per cell per tick.
@MainActor
enum Format {
    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowsNonnumericFormatting = false
        return f
    }()

    /// "1.2 GB"
    static func bytes(_ value: UInt64) -> String { bytes.string(fromByteCount: Int64(clamping: value)) }

    /// "3.4 MB/s"; "0 MB/s" style zero like Task Manager.
    static func rate(_ bytesPerSec: Double) -> String {
        guard bytesPerSec >= 1 else { return "0 MB/s" }
        return bytes.string(fromByteCount: Int64(bytesPerSec)) + "/s"
    }

    /// Core fraction (1.0 = one core) → "12.3%" of one core, Activity Monitor style.
    static func cpuPercent(_ cores: Double) -> String { String(format: "%.1f%%", cores * 100) }

    /// 0...1 → "4.4%"
    static func percentOneDecimal(_ fraction: Double) -> String { String(format: "%.1f%%", fraction * 100) }

    /// 0...1 → "45%"
    static func percent(_ fraction: Double) -> String { String(format: "%.0f%%", fraction * 100) }

    /// "Mbps" for network graphs, like Task Manager.
    static func bitsRate(_ bytesPerSec: Double) -> String {
        let bits = bytesPerSec * 8
        switch bits {
        case ..<1_000: return String(format: "%.0f bps", bits)
        case ..<1_000_000: return String(format: "%.1f Kbps", bits / 1_000)
        case ..<1_000_000_000: return String(format: "%.1f Mbps", bits / 1_000_000)
        default: return String(format: "%.2f Gbps", bits / 1_000_000_000)
        }
    }
}
