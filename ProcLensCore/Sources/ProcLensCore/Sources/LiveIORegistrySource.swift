// Adapted from exelban/stats@ee4265f3, Modules/GPU/reader.swift (InfoReader.read: IOAccelerator PerformanceStatistics)
// and Modules/Disk/readers.swift (ActivityReader: IOBlockStorageDriver Statistics)
// Copyright (c) 2019 Serhiy Mytrovtsiy, MIT License (see THIRD_PARTY_NOTICES.md)

import Foundation
import IOKit

/// Public IOKit registry reads. Matching services are enumerated once and their handles kept
/// (re-enumerated every `refreshEvery` reads or when a cached device stops answering, so hot-plugged
/// disks still show up); only the property read happens each tick. Handles are released in `deinit`.
public final class LiveIORegistrySource: IORegistrySource, @unchecked Sendable {
    private struct Cache {
        var services: [io_registry_entry_t] = []
        var names: [io_registry_entry_t: String] = [:]
        var readsSinceRefresh = 1_000_000
    }

    static let refreshEvery = 30
    private let lock = NSLock()
    private var gpu = Cache()
    private var block = Cache()

    public init() {}

    deinit {
        for s in gpu.services + block.services { IOObjectRelease(s) }
    }

    public func gpuDevices() throws -> [GPUDeviceSample] {
        lock.lock(); defer { lock.unlock() }
        try refreshIfNeeded(&gpu, className: "IOAccelerator")
        var devices: [GPUDeviceSample] = []
        for service in gpu.services {
            guard let stats = Self.property(service, "PerformanceStatistics") as? [String: Any] else { continue }
            // Apple Silicon reports "Device Utilization %"; some Intel/AMD drivers use "GPU Activity(%)".
            guard let percent = Self.number(stats["Device Utilization %"]) ?? Self.number(stats["GPU Activity(%)"]) else { continue }
            let name: String
            if let cached = gpu.names[service] {
                name = cached
            } else {
                name = Self.modelName(of: service) ?? (stats["model"] as? String) ?? "GPU"
                gpu.names[service] = name
            }
            devices.append(GPUDeviceSample(name: name, utilization: min(1, max(0, percent / 100))))
        }
        return devices
    }

    public func blockDevices() throws -> [BlockDeviceCounters] {
        lock.lock(); defer { lock.unlock() }
        try refreshIfNeeded(&block, className: "IOBlockStorageDriver")
        var devices: [BlockDeviceCounters] = []
        var stale = false
        for service in block.services {
            guard let stats = Self.property(service, "Statistics") as? [String: Any],
                  let read = Self.number(stats["Bytes (Read)"]),
                  let written = Self.number(stats["Bytes (Write)"]) else { stale = true; continue }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            devices.append(BlockDeviceCounters(id: String(entryID), bytesRead: UInt64(max(0, read)),
                                               bytesWritten: UInt64(max(0, written))))
        }
        if stale { block.readsSinceRefresh = 1_000_000 }  // a device went away: re-enumerate next read
        return devices
    }

    // MARK: Helpers

    private func refreshIfNeeded(_ cache: inout Cache, className: String) throws {
        cache.readsSinceRefresh += 1
        guard cache.readsSinceRefresh >= Self.refreshEvery else { return }
        var fresh: [io_registry_entry_t] = []
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator)
        guard kr == KERN_SUCCESS else { throw SourceError("IOServiceGetMatchingServices(\(className))", errno: kr) }
        while case let service = IOIteratorNext(iterator), service != 0 { fresh.append(service) }
        IOObjectRelease(iterator)
        for old in cache.services { IOObjectRelease(old) }
        cache.services = fresh
        cache.names = [:]
        cache.readsSinceRefresh = 0
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// "model" is a NUL-terminated Data/String on the accelerator (Apple GPU) or its PCI parent (discrete GPU).
    private static func modelName(of service: io_registry_entry_t) -> String? {
        func decode(_ value: Any?) -> String? {
            let raw: String?
            if let s = value as? String { raw = s }
            else if let d = value as? Data { raw = String(data: d, encoding: .utf8) }
            else { raw = nil }
            let trimmed = raw?.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespaces)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
        if let name = decode(property(service, "model")) { return name }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        return decode(property(parent, "model"))
    }
}
