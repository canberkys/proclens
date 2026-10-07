import Darwin

/// One memory region of a process with a backing file (`PROC_PIDREGIONPATHINFO`).
public struct MemoryRegion: Sendable, Hashable {
    public var address: UInt64
    public var size: UInt64
    /// `VM_PROT_*` bits of the region's current protection.
    public var protection: UInt32
    /// Backing file path; empty for anonymous memory.
    public var path: String
    public init(address: UInt64, size: UInt64, protection: UInt32, path: String) {
        self.address = address
        self.size = size
        self.protection = protection
        self.path = path
    }
    public var isExecutable: Bool { protection & 0x4 != 0 }
}

public protocol RegionSource: Sendable {
    /// The first region at or after `address`, or nil when there are no more regions.
    /// Throws on `ESRCH`/`EPERM`.
    func region(pid: pid_t, atOrAfter address: UInt64) throws -> MemoryRegion?
}

public struct LiveRegionSource: RegionSource {
    public init() {}

    public func region(pid: pid_t, atOrAfter address: UInt64) throws -> MemoryRegion? {
        var info = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &info, size)
        if got <= 0 {
            let e = errno
            // ESRCH = gone, EPERM/EACCES = restricted; anything else (EINVAL past the last region) ends the walk.
            if e == ESRCH || e == EPERM || e == EACCES { throw SourceError("proc_pidinfo(REGIONPATHINFO)", errno: e) }
            return nil
        }
        let path = withUnsafeBytes(of: &info.prp_vip.vip_path) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        let r = info.prp_prinfo
        return MemoryRegion(address: r.pri_address, size: r.pri_size, protection: r.pri_protection, path: path)
    }
}

/// A file mapped into a process, de-duplicated by path.
public struct LoadedImage: Sendable, Hashable, Identifiable {
    public var path: String
    public var baseAddress: UInt64
    public var totalSize: UInt64
    public var regionCount: Int
    /// True when at least one region of this file is mapped executable (dylib/binary text, vs data files).
    public var isExecutable: Bool
    public var id: String { path }
}

/// On-demand list of files mapped into a process (executable, dylibs, frameworks, mmap'd data).
///
/// Limitation: libraries from the dyld shared cache are mapped as one big cache file, so they are
/// NOT listed individually; you see the cache file, not each system dylib. Listing them would need
/// dyld image info from the target (`task_for_pid`), which needs entitlements/the helper.
public actor LoadedImagesInspector {
    private let source: any RegionSource
    private static let maxRegions = 200_000

    public init(source: any RegionSource = LiveRegionSource()) {
        self.source = source
    }

    public func images(pid: pid_t) async throws -> [LoadedImage] {
        var byPath: [String: LoadedImage] = [:]
        var order: [String] = []
        var address: UInt64 = 0
        var iterations = 0
        while iterations < Self.maxRegions, let region = try source.region(pid: pid, atOrAfter: address) {
            iterations += 1
            if !region.path.isEmpty {
                if var image = byPath[region.path] {
                    image.baseAddress = min(image.baseAddress, region.address)
                    image.totalSize &+= region.size
                    image.regionCount += 1
                    image.isExecutable = image.isExecutable || region.isExecutable
                    byPath[region.path] = image
                } else {
                    byPath[region.path] = LoadedImage(path: region.path, baseAddress: region.address,
                                                      totalSize: region.size, regionCount: 1,
                                                      isExecutable: region.isExecutable)
                    order.append(region.path)
                }
            }
            let (next, overflow) = region.address.addingReportingOverflow(region.size)
            // Must advance strictly, otherwise a zero-size region would loop forever.
            if overflow || region.size == 0 || next <= address { break }
            address = next
        }
        return order.compactMap { byPath[$0] }
    }
}
