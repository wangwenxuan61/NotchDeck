import Foundation
import IOKit

// MARK: - SMC

private struct SMCVersion { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
// 末尾的填充字节不能省：Swift 不会像 C 那样补齐结构体，缺了后面字段的偏移就错了。
private struct SMCKeyInfo { var size: UInt32 = 0, type: UInt32 = 0; var attributes: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0, pad3: UInt8 = 0 }
private struct SMCParam {
    var key: UInt32 = 0
    var version = SMCVersion()
    var limit = SMCLimit()
    var info = SMCKeyInfo()
    var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
}

final class SMC {
    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyInfo] = [:]
    private(set) var cpuKeys: [UInt32] = []
    private(set) var gpuKeys: [UInt32] = []
    private(set) var fanCount = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        discover()
    }

    private static func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func call(_ input: inout SMCParam) -> SMCParam? {
        var output = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let status = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParam>.stride, &output, &size)
        return status == KERN_SUCCESS ? output : nil
    }

    private func info(_ key: UInt32) -> SMCKeyInfo? {
        if let cached = infoCache[key] { return cached }
        var input = SMCParam()
        input.key = key
        input.command = 9
        guard let output = call(&input), output.result == 0 else { return nil }
        infoCache[key] = output.info
        return output.info
    }

    private func bytes(_ key: UInt32) -> (type: UInt32, bytes: (UInt64, UInt64, UInt64, UInt64))? {
        guard let keyInfo = info(key) else { return nil }
        var input = SMCParam()
        input.key = key
        input.info = keyInfo
        input.command = 5
        guard let output = call(&input), output.result == 0 else { return nil }
        return (keyInfo.type, output.bytes)
    }

    private func discover() {
        guard let raw = bytes(Self.code("#KEY")) else { return }
        var storage = raw.bytes
        let total = withUnsafeBytes(of: &storage) { UInt32(bigEndian: $0.load(as: UInt32.self)) }
        for index in 0..<total {
            var input = SMCParam()
            input.command = 8
            input.data32 = index
            guard let output = call(&input), output.result == 0 else { continue }
            let prefix = output.key >> 16
            if prefix == Self.code("Tp") || prefix == Self.code("Te") {
                if temperature(output.key) != nil { cpuKeys.append(output.key) }
            } else if prefix == Self.code("Tg") {
                if temperature(output.key) != nil { gpuKeys.append(output.key) }
            }
        }
        if let raw = bytes(Self.code("FNum")) {
            fanCount = Int(raw.bytes.0 & 0xFF)
        }
    }

    func float(_ key: UInt32) -> Double? {
        guard let raw = bytes(key), raw.type == Self.code("flt ") else { return nil }
        var storage = raw.bytes
        return withUnsafeBytes(of: &storage) { Double($0.loadUnaligned(as: Float.self)) }
    }

    private func temperature(_ key: UInt32) -> Double? {
        guard let value = float(key), value > 5, value < 130 else { return nil }
        return value
    }

    func temperatures(_ keys: [UInt32]) -> [Double] { keys.compactMap(temperature) }
    var systemPower: Double? { float(Self.code("PSTR")).flatMap { $0 > 0 ? $0 : nil } }
    func fanSpeed(_ index: Int) -> Double? { float(Self.code("F\(index)Ac")) }
}

// MARK: - HID sensors

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

final class HIDSensors {
    private let client: AnyObject
    private var services: [(name: String, service: AnyObject)] = []

    init?() {
        guard let created = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        client = created
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary)
        let list = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] ?? []
        services = list.compactMap { service in
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String else { return nil }
            return (name, service)
        }
    }

    private func read(_ service: AnyObject) -> Double? {
        guard let event = IOHIDServiceClientCopyEvent(service, 15, 0, 0)?.takeRetainedValue() else { return nil }
        let value = IOHIDEventGetFloatValue(event, 15 << 16)
        return value > 5 && value < 130 ? value : nil
    }

    func maxTemperature(matching predicate: (String) -> Bool) -> Double? {
        services.filter { predicate($0.name) }.compactMap { read($0.service) }.max()
    }
}
