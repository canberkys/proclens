// Adapted from exelban/stats@ee4265f3, Modules/GPU/reader.swift (InfoReader.read: IOAccelerator PerformanceStatistics)
// and Modules/Disk/readers.swift (ActivityReader: IOBlockStorageDriver Statistics)
// Copyright (c) 2019 Serhiy Mytrovtsiy, MIT License (see THIRD_PARTY_NOTICES.md)

import Foundation
import IOKit

/// Public IOKit registry reads. Stateless, so trivially `Sendable`. Every `io_object_t` is released.
public struct LiveIORegistrySource: IORegistrySource {
    public init() {}

    public func gpuDevices() throws -> [GPUDeviceSample] {
        var devices: [GPUDeviceSample] = []
        try Self.forEachService(matching: "IOAccelerator") { service in
            guard let stats = Self.property(service, "PerformanceStatistics") as? [String: Any] else { return }
            // Apple Silicon reports "Device Utilization %"; some Intel/AMD drivers use "GPU Activity(%)".
            guard let percent = Self.number(stats["Device Utilization %"]) ?? Self.number(stats["GPU Activity(%)"]) else { return }
            let name = Self.modelName(of: service) ?? (stats["model"] as? String) ?? "GPU"
            devices.append(GPUDeviceSample(name: name, utilization: min(1, max(0, percent / 100))))
        }
        return devices
    }

    public func blockDevices() throws -> [BlockDeviceCounters] {
        var devices: [BlockDeviceCounters] = []
        try Self.forEachService(matching: "IOBlockStorageDriver") { service in
            guard let stats = Self.property(service, "Statistics") as? [String: Any],
                  let read = Self.number(stats["Bytes (Read)"]),
                  let written = Self.number(stats["Bytes (Write)"]) else { return }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            devices.append(BlockDeviceCounters(id: String(entryID), bytesRead: UInt64(max(0, read)),
                                               bytesWritten: UInt64(max(0, written))))
        }
        return devices
    }

    // MARK: Helpers

    /// Runs `body` for each service matching the class, releasing the iterator and every service.
    private static func forEachService(matching className: String, _ body: (io_registry_entry_t) -> Void) throws {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator)
        guard kr == KERN_SUCCESS else { throw SourceError("IOServiceGetMatchingServices(\(className))", errno: kr) }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
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
