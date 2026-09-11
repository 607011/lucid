import CoreGraphics
import Foundation
import IOKit

/// Fallback for third-party displays that don't support
/// `NativeDisplayBrightness` (i.e. aren't the built-in panel, a Studio
/// Display, or a Pro Display XDR): controls brightness via DDC/CI (VESA
/// Monitor Control Command Set) sent over the private `IOAVService` I2C
/// transport – the same undocumented mechanism used by MonitorControl,
/// Lunar and ddcutil. Apple has never shipped a public API for this.
///
/// ⚠️ Unlike `NativeDisplayBrightness`, this has **not** been verified
/// against real hardware (no external monitor was available while writing
/// it). The DDC/CI byte-level protocol below follows the public VESA
/// MCCS spec as closely as possible, but the private `IOAVService`
/// transport details are reverse-engineered community knowledge, and DDC
/// support varies a lot by monitor/cable/hub even when everything here is
/// correct. Every call fails silently (returns `false`/does nothing) so a
/// wrong implementation just means external displays don't dim – it
/// can't crash the app or affect the built-in display / "turn off"
/// mode.
enum ExternalDisplayBrightness {

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias WriteI2CFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeRawPointer, UInt32) -> IOReturn
    private typealias ReadI2CFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    // These symbols live in IOKit.framework (undocumented, no header).
    // dlopen (rather than relying on already-linked IOKit + RTLD_DEFAULT)
    // makes the dependency explicit and keeps this self-contained.
    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/IOKit.framework/IOKit",
        RTLD_LAZY
    )

    private static let ioAVServiceCreate: CreateFn? = symbol("IOAVServiceCreate")
    private static let ioAVServiceWriteI2C: WriteI2CFn? = symbol("IOAVServiceWriteI2C")
    private static let ioAVServiceReadI2C: ReadI2CFn? = symbol("IOAVServiceReadI2C")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    static var isSupported: Bool {
        ioAVServiceCreate != nil && ioAVServiceWriteI2C != nil && ioAVServiceReadI2C != nil
    }

    // MARK: - Finding AVServices

    /// One AVService per AV-capable display connection, best-effort.
    /// Lucid only ever dims/restores "all external displays" as a group
    /// (never a specific one), so unlike MonitorControl this deliberately
    /// doesn't need to match a service back to a particular
    /// `CGDirectDisplayID` – it just needs every service that can receive
    /// DDC commands.
    ///
    /// `CGDisplayIOServicePort`, the old direct display-to-service
    /// lookup, has been unavailable since OS X 10.9 – the only remaining
    /// option is enumerating every "DCPAVServiceProxy" in the IORegistry,
    /// which is also what current DDC tools (MonitorControl etc.) do.
    static func allExternalServices() -> [AnyObject] {
        discoverAVServiceProxies()
    }

    /// Every "DCPAVServiceProxy" in the IORegistry is an AV-capable
    /// display connection. Wrapped with `IOAVServiceCreate`.
    private static func discoverAVServiceProxies() -> [AnyObject] {
        guard let ioAVServiceCreate else { return [] }
        guard let matching = IOServiceMatching("DCPAVServiceProxy") else { return [] }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var services: [AnyObject] = []
        var ioService = IOIteratorNext(iterator)
        while ioService != 0 {
            defer { ioService = IOIteratorNext(iterator) }
            if let service = ioAVServiceCreate(nil)?.takeRetainedValue() {
                services.append(service)
            }
            IOObjectRelease(ioService)
        }
        return services
    }

    // MARK: - DDC/CI (VESA MCCS)

    /// VCP feature code for "Luminance" (brightness).
    private static let vcpBrightnessCode: UInt8 = 0x10

    /// I2C address DDC/CI communicates on (7-bit 0x37, used as an 8-bit
    /// write address by IOAVService's `chipAddress` parameter).
    private static let ddcChipAddress: UInt32 = 0x37

    /// Reads the current brightness (raw VCP value, monitor-defined
    /// range – often but not always 0...100) of a service, or `nil` on
    /// any failure.
    static func brightness(of service: AnyObject) -> UInt16? {
        guard let ioAVServiceWriteI2C, let ioAVServiceReadI2C else { return nil }

        // "Get VCP Feature" request.
        let request: [UInt8] = ddcMessage(opcode: 0x01, payload: [vcpBrightnessCode])
        let writeStatus = request.withUnsafeBytes { buffer -> IOReturn in
            guard let base = buffer.baseAddress else { return kIOReturnError }
            return ioAVServiceWriteI2C(service, ddcChipAddress, 0x51, base, UInt32(buffer.count))
        }
        guard writeStatus == kIOReturnSuccess else { return nil }

        // Displays need a moment to prepare the reply.
        usleep(50_000)

        var reply = [UInt8](repeating: 0, count: 11)
        let readStatus = reply.withUnsafeMutableBytes { buffer -> IOReturn in
            guard let base = buffer.baseAddress else { return kIOReturnError }
            return ioAVServiceReadI2C(service, ddcChipAddress, 0x51, base, UInt32(buffer.count))
        }
        guard readStatus == kIOReturnSuccess else { return nil }

        // Reply layout (after the 0x6E/length/opcode header at [0...2]):
        // [3]=result code [4]=VCP code [5]=type [6..7]=max (hi/lo) [8..9]=current (hi/lo)
        guard reply.count >= 10, reply[4] == vcpBrightnessCode else { return nil }
        return (UInt16(reply[8]) << 8) | UInt16(reply[9])
    }

    /// Sets brightness to a raw VCP value. Returns `true` if the I2C
    /// write itself succeeded (monitors don't ack DDC/CI writes, so this
    /// can't confirm the monitor actually changed brightness).
    @discardableResult
    static func setBrightness(_ value: UInt16, of service: AnyObject) -> Bool {
        guard let ioAVServiceWriteI2C else { return false }

        let payload: [UInt8] = [vcpBrightnessCode, UInt8(value >> 8), UInt8(value & 0xFF)]
        let message = ddcMessage(opcode: 0x03, payload: payload)
        let status = message.withUnsafeBytes { buffer -> IOReturn in
            guard let base = buffer.baseAddress else { return kIOReturnError }
            return ioAVServiceWriteI2C(service, ddcChipAddress, 0x51, base, UInt32(buffer.count))
        }
        return status == kIOReturnSuccess
    }

    /// Builds a DDC/CI message: `[0x51, length, opcode, ...payload, checksum]`,
    /// checksum = XOR of the virtual write address (0x6E) with every
    /// preceding byte, per the VESA DDC/CI specification.
    private static func ddcMessage(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
        let lengthByte: UInt8 = 0x80 | UInt8(1 + payload.count)
        var message: [UInt8] = [0x51, lengthByte, opcode] + payload
        let checksum = message.reduce(UInt8(0x6E)) { $0 ^ $1 }
        message.append(checksum)
        return message
    }
}
