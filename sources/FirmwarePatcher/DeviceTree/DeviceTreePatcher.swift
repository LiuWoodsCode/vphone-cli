// DeviceTreePatcher.swift — DeviceTree payload patcher.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Strategy:
//   1. Parse the flat device tree binary into a node/property tree.
//   2. Apply the iPad15,3 identity and capability profile.
//   3. Serialize the modified tree back to flat binary.

import Foundation

/// Patcher for DeviceTree payloads.
public final class DeviceTreePatcher: Patcher {
    public let component = "devicetree"
    public let verbose: Bool

    let buffer: BinaryBuffer
    var patches: [PatchRecord] = []
    var rebuiltData: Data?

    // MARK: - Patch Definitions

    /// A single property patch specification.
    struct PropertyPatch {
        let nodePath: [String]
        let property: String
        let length: Int
        let flags: UInt16
        let value: PropertyValue
        let patchID: String
        let description: String
    }

    /// A patch that adds a child capability node under an existing parent.
    struct AddChildNodePatch {
        let parentPath: [String]
        let nodeName: String
        /// Properties to place inside the new node. The `name` property is
        /// added automatically from `nodeName`; do not include it here.
        let properties: [PropertySpec]
        let patchID: String
        let description: String

        struct PropertySpec {
            let name: String
            let length: Int
            let flags: UInt16
            let value: PropertyValue
        }
    }

    /// The value to write into a device tree property.
    enum PropertyValue {
        case string(String)
        case integer(UInt64)
        /// Raw bytes — used when the property holds a multi-string blob
        /// (NUL-delimited cstrings packed back-to-back, e.g. `compatible`)
        /// where Swift String escaping of embedded NULs is awkward.
        case bytes(Data)
    }

    // Keep the virtual platform matcher first so the guest boot driver still binds.
    static let compatibleRewrite = Data("VPHONE600AP\0iPad15,3\0AppleVirtualPlatformARM\0\0".utf8)

    static let basePropertyPatches: [PropertyPatch] = [
        PropertyPatch(nodePath: ["device-tree"], property: "serial-number", length: 12, flags: 0, value: .string("FLVRF0LEY01"), patchID: "devicetree.ipad.serial_number", description: "Preserve fake Flavor Foley serial number"),
        PropertyPatch(nodePath: ["device-tree"], property: "model-number", length: 32, flags: 0, value: .string("MC9X4"), patchID: "devicetree.ipad.model_number", description: "Set iPad model number MC9X4"),
        PropertyPatch(nodePath: ["device-tree"], property: "compatible", length: 48, flags: 0, value: .bytes(compatibleRewrite), patchID: "devicetree.ipad.compatible", description: "Set compatible secondary model to iPad15,3"),
        PropertyPatch(nodePath: ["device-tree", "arm-io"], property: "soc-generation", length: 11, flags: 0, value: .string("H15"), patchID: "devicetree.ipad.soc_generation", description: "Set iPad SoC generation"),
        PropertyPatch(nodePath: ["device-tree", "arm-io"], property: "device_type", length: 14, flags: 0, value: .string("t8122-io"), patchID: "devicetree.ipad.device_type", description: "Set iPad SoC device type"),
    ]

    /// Literal /product property snapshot from the supplied J607AP IORegistry dump.
    /// Only product-name keeps the project's fake value.
    private static func hexBytes(_ text: String) -> Data {
        let chars = Array(text.utf8)
        precondition(chars.count.isMultiple(of: 2))
        return Data(stride(from: 0, to: chars.count, by: 2).map { i in
            UInt8(String(decoding: chars[i ... i + 1], as: UTF8.self), radix: 16)!
        })
    }

    static let iPadProductProperties: [AddChildNodePatch.PropertySpec] = [
        .init(name: "lockdown-certtype", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "display-mirroring", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "assistant", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "sandman-support", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "fdr-product-type", length: 9, flags: 0, value: .string("iPad15,3")),
        .init(name: "ui-pip", length: 0, flags: 0, value: .bytes(hexBytes(""))),
        .init(name: "wifi-chipset", length: 5, flags: 0, value: .string("4388")),
        .init(name: "supports-third-party-drivers", length: 0, flags: 0, value: .bytes(hexBytes(""))),
        .init(name: "bluetooth-lea2", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "product-name", length: 15, flags: 0, value: .string("Butcher Vanity")),
        .init(name: "hearingaid-audio-equalization", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "RF-exposure-separation-distance", length: 4, flags: 0, value: .bytes(hexBytes("05000000"))),
        .init(name: "mobiledevice-min-ver", length: 12, flags: 0, value: .string("1827.100.14")),
        .init(name: "product-id", length: 20, flags: 0, value: .bytes(hexBytes("32ec6f983b5e984241068e698417d5a10c3a96c1"))),
        .init(name: "sub-product-type", length: 9, flags: 0, value: .string("iPad15,3")),
        .init(name: "raw-panel-serial-number", length: 87, flags: 0, value: .string("FP1HHS00CPK0000NJLAAAE6BLNGA661DY9HHC00ELC0000NJJXXX9FQQ81D251C43HH6TZ9WM00004WZ180XX3")),
        .init(name: "product-description", length: 15, flags: 0, value: .string("Butcher Vanity")),
        .init(name: "supports-recoveryos", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "natural-volume-arrangement", length: 0, flags: 0, value: .bytes(hexBytes(""))),
        .init(name: "allow-32bit-apps", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "panel-product-id", length: 2, flags: 0, value: .bytes(hexBytes("74c1"))),
        .init(name: "low-power-wallet-mode", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "builtin-mics", length: 4, flags: 0, value: .bytes(hexBytes("02000000"))),
        .init(name: "exclaves-enabled", length: 4, flags: 0, value: .bytes(hexBytes("00000000"))),
        .init(name: "has-boot-chime", length: 4, flags: 0, value: .bytes(hexBytes("00000000"))),
        .init(name: "rear-cam-offset-from-center", length: 20, flags: 0, value: .bytes(hexBytes("14b20100152b0100f60c0000e803000000000000"))),
        .init(name: "unique-model", length: 7, flags: 0, value: .string("J607AP")),
        .init(name: "display-backlight-compensation", length: 116, flags: 0, value: .bytes(hexBytes("00000002000033330000ea77000100000000fed3000200000000ee370000feed00010000000500000000f1c50000fe3100010000000900000000f5fb0000fe4200010000000f00000000fb6e0000ff1d000100000014fae10001000000010000000100000016a666000100000000fee90000feba"))),
        .init(name: "compatible-device-fallback", length: 9, flags: 0, value: .string("iPad14,8")),
        .init(name: "external-hdr", length: 0, flags: 0, value: .bytes(hexBytes(""))),
        .init(name: "device-perf-memory-class", length: 4, flags: 0, value: .bytes(hexBytes("08000000"))),
        .init(name: "display-corner-radius", length: 8, flags: 0, value: .bytes(hexBytes("1200000001000000"))),
        .init(name: "artwork-scale-factor", length: 4, flags: 0, value: .bytes(hexBytes("02000000"))),
        .init(name: "has-exclaves", length: 4, flags: 0, value: .bytes(hexBytes("00000000"))),
        .init(name: "strict-wake-vendor-id", length: 16, flags: 0, value: .bytes(hexBytes("ac050000ac050000ac050000ac050000"))),
        .init(name: "hearingaid-low-energy-audio", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "ui-background-quality", length: 4, flags: 0, value: .bytes(hexBytes("64000000"))),
        .init(name: "strict-wake-product-id", length: 16, flags: 0, value: .bytes(hexBytes("920200006e0200006f02000051040000"))),
        .init(name: "supports-avatars", length: 0, flags: 0, value: .bytes(hexBytes(""))),
        .init(name: "public-key-accelerator", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "panel-serial-number", length: 19, flags: 0, value: .string("FP1HHS00CPK0000NJL")),
        .init(name: "name", length: 8, flags: 0, value: .string("product")),
        .init(name: "artwork-device-idiom", length: 4, flags: 0, value: .string("pad")),
        .init(name: "has-virtualization", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "device-color-policy", length: 4, flags: 0, value: .bytes(hexBytes("00000000"))),
        .init(name: "graphics-featureset-class", length: 7, flags: 0, value: .string("APPLE9")),
        .init(name: "AAPL,phandle", length: 4, flags: 0, value: .bytes(hexBytes("00010000"))),
        .init(name: "compatible-app-variant", length: 2, flags: 0, value: .string("0")),
        .init(name: "artwork-dynamic-displaymode", length: 2, flags: 0, value: .string("0")),
        .init(name: "bluetooth-le", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "supports-lotx", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "has-applelpm", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "framebuffer-identifier", length: 37, flags: 0, value: .string("1D05B7BF-7313-48A6-B2DF-964AAE76A0DC")),
        .init(name: "iap2-protocol-supported", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "ui-overlay-app", length: 0, flags: 0, value: .bytes(hexBytes(""))),
        .init(name: "ephemeral-data-mode", length: 4, flags: 0, value: .bytes(hexBytes("00000000"))),
        .init(name: "front-cam-rotation-isp", length: 4, flags: 0, value: .bytes(hexBytes("b4000000"))),
        .init(name: "chrome-identifier", length: 38, flags: 0, value: .string("com.apple.dt.devicekit.chrome.tablet4")),
        .init(name: "app-macho-architecture", length: 7, flags: 0, value: .string("arm64e")),
        .init(name: "ptp-large-files", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "medusa-overlay-app-capability", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "udid-version", length: 4, flags: 0, value: .bytes(hexBytes("02000000"))),
        .init(name: "offline-dictation", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "ui-weather-quality", length: 4, flags: 0, value: .bytes(hexBytes("64000000"))),
        .init(name: "graphics-featureset-fallbacks", length: 73, flags: 0, value: .string("APPLE8:APPLE7:APPLE6:APPLE5:APPLE4:APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0")),
        .init(name: "dictation", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "itunes-min-ver", length: 4, flags: 0, value: .bytes(hexBytes("00090c00"))),
        .init(name: "multiuser-sessions", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "artwork-display-gamut", length: 3, flags: 0, value: .string("P3")),
        .init(name: "front-cam-offset-from-center", length: 20, flags: 0, value: .bytes(hexBytes("1c250000254b010078100000e803000000000000"))),
        .init(name: "partition-style", length: 4, flags: 0, value: .string("iOS")),
        .init(name: "single-stage-boot", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "thin-bezel", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "ui-floating-live-app", length: 0, flags: 0, value: .bytes(hexBytes(""))),
        .init(name: "ui-pinned-app", length: 0, flags: 0, value: .bytes(hexBytes(""))),
        .init(name: "display-temp-compensation", length: 164, flags: 0, value: .bytes(hexBytes("000000010012b3330000f5d50000f7f700010000001500000000f7f50000f9a700010000001800000000fac10000fbdf00010000001b00000000fd950000fe1a00010000001d88f600010000000100000001000000200000000100000000ff7d0000fda600230000000100000000fedc0000fad100260000000100000000fe3b0000f80400290000000100000000fd980000f53f002d0000000100000000fcbe0000f199"))),
        .init(name: "builtin-battery", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "artwork-device-subtype", length: 4, flags: 0, value: .bytes(hexBytes("38090000"))),
        .init(name: "reverse-zoom-supported", length: 4, flags: 0, value: .bytes(hexBytes("01000000"))),
        .init(name: "primary-calibration-matrix", length: 40, flags: 0, value: .bytes(hexBytes("0100000046f4fc00b88f0500027cfdffbe1901009a5bfa00a78a0400aa25ffffec3800006aa10001"))),
        .init(name: "usb-c-smc-pwr", length: 0, flags: 0, value: .bytes(hexBytes(""))),
        .init(name: "side-button-location", length: 20, flags: 0, value: .bytes(hexBytes("0006180000922200f45e00000787020010270000"))),
    ]

    static let iPadNodeAdditions: [AddChildNodePatch] = [
        AddChildNodePatch(parentPath: ["device-tree", "product"], nodeName: "camera", properties: [
                .init(name: "rear-max-video-fps-4k", length: 4, flags: 0, value: .integer(60)),
                .init(name: "rear-max-video-zoom", length: 4, flags: 0, value: .integer(3)),
                .init(name: "rear-max-burst-length", length: 4, flags: 0, value: .integer(300)),
                .init(name: "camera-hdr-version", length: 4, flags: 0, value: .integer(3)),
                .init(name: "front-max-burst-length", length: 4, flags: 0, value: .integer(300)),
                .init(name: "auto-focus", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-auto-hdr", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-max-video-fps-720p", length: 4, flags: 0, value: .integer(60)),
                .init(name: "front-burst-image-duration", length: 4, flags: 0, value: .integer(100)),
                .init(name: "rear-slowmo", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-hdr", length: 4, flags: 0, value: .integer(1)),
                .init(name: "pipelined-stillimage-capability", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-max-slomo-video-fps-1080p", length: 4, flags: 0, value: .integer(240)),
                .init(name: "front-flash-capability", length: 4, flags: 0, value: .integer(1)),
                .init(name: "video-cap", length: 4, flags: 0, value: .integer(2)),
                .init(name: "front-hdr-on", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-max-slomo-video-fps-720p", length: 4, flags: 0, value: .integer(240)),
                .init(name: "front-burst", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-auto-hdr", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-burst-image-duration", length: 4, flags: 0, value: .integer(100)),
                .init(name: "p3-color-space-video-recording", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-max-video-frame_rate", length: 4, flags: 0, value: .integer(60)),
                .init(name: "rear-hdr-on", length: 4, flags: 0, value: .integer(1)),
                .init(name: "auto-low-light-video", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-max-video-fps-1080p", length: 4, flags: 0, value: .integer(60)),
                .init(name: "medusa-overlay-app-capability", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-hdr", length: 4, flags: 0, value: .integer(1)),
                .init(name: "rear-burst", length: 4, flags: 0, value: .integer(1)),
                .init(name: "post-effects", length: 4, flags: 0, value: .integer(1)),
                .init(name: "photo-capture-on-touch-down", length: 4, flags: 0, value: .integer(1)),
                .init(name: "stage-light-portrait-preview", length: 4, flags: 0, value: .integer(0)),
                .init(name: "front-max-video-zoom", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-max-video-fps-720p", length: 4, flags: 0, value: .integer(60)),
                .init(name: "panorama", length: 4, flags: 0, value: .integer(1)),
                .init(name: "front-max-video-fps-1080p", length: 4, flags: 0, value: .integer(60)),
                .init(name: "live-photo-capture", length: 4, flags: 0, value: .integer(1)),
            ], patchID: "devicetree.ipad.camera_node", description: "Add iPad15,3 camera capabilities"),
        AddChildNodePatch(parentPath: ["device-tree", "product"], nodeName: "facetime", properties: [
                .init(name: "encoding", length: 56, flags: 0, value: .bytes(Data([ 0x40, 0x01, 0x00, 0x00, 0x0f, 0x00, 0xf0, 0x00, 0x40, 0x01, 0x00, 0x00, 0x1e, 0x00, 0xf0, 0x00, 0xe0, 0x01, 0x00, 0x00, 0x0f, 0x00, 0x70, 0x01, 0xe0, 0x01, 0x00, 0x00, 0x1e, 0x00, 0x70, 0x01, 0x80, 0x02, 0x00, 0x00, 0x1e, 0x00, 0xe0, 0x01, 0x00, 0x04, 0x00, 0x00, 0x1e, 0x00, 0x00, 0x03, 0x00, 0x05, 0x00, 0x00, 0x1e, 0x00, 0xd0, 0x02 ]))),
                .init(name: "decoding", length: 48, flags: 0, value: .bytes(Data([ 0x40, 0x01, 0x00, 0x00, 0x0f, 0x00, 0xf0, 0x00, 0x40, 0x01, 0x00, 0x00, 0x1e, 0x00, 0xf0, 0x00, 0xe0, 0x01, 0x00, 0x00, 0x0f, 0x00, 0x70, 0x01, 0xe0, 0x01, 0x00, 0x00, 0x1e, 0x00, 0x70, 0x01, 0x80, 0x02, 0x00, 0x00, 0x1e, 0x00, 0xe0, 0x01, 0x00, 0x04, 0x00, 0x00, 0x1e, 0x00, 0x00, 0x03 ]))),
                .init(name: "tnr-mode-front", length: 4, flags: 0, value: .integer(10)),
                .init(name: "pref-decoding", length: 8, flags: 0, value: .bytes(Data([ 0x00, 0x04, 0x00, 0x00, 0x1e, 0x00, 0x00, 0x03 ]))),
                .init(name: "bitrate-wifi", length: 4, flags: 0, value: .integer(2000)),
                .init(name: "tnr-mode-back", length: 4, flags: 0, value: .integer(10)),
            ], patchID: "devicetree.ipad.facetime_node", description: "Add iPad15,3 facetime capabilities"),
        AddChildNodePatch(parentPath: ["device-tree", "product"], nodeName: "audio", properties: [
                .init(name: "supports-auto-mic-mode", length: 4, flags: 0, value: .integer(0)),
                .init(name: "supports-secure-microphone", length: 4, flags: 0, value: .integer(1)),
                .init(name: "acoustic-id", length: 4, flags: 0, value: .integer(2025)),
                .init(name: "stereo-sound-recording", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-audio-mix", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-advanced-vp-chatflavor", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-always-listening", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-spatial-facetime", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-barge-in", length: 4, flags: 0, value: .integer(1)),
                .init(name: "wireless-splitter", length: 4, flags: 0, value: .integer(1)),
                .init(name: "usb-uses-audio-clock", length: 4, flags: 0, value: .integer(1)),
                .init(name: "supports-concurrent-hp-lp-mics", length: 4, flags: 0, value: .integer(1)),
            ], patchID: "devicetree.ipad.audio_node", description: "Add iPad15,3 audio capabilities"),
    ]

    // MARK: - Device Tree Structures

    /// A single property in a device tree node.
    final class DTProperty {
        var name: String
        var length: Int
        var flags: UInt16
        var value: Data
        /// File offset of the property value within the flat binary.
        let valueOffset: Int

        init(name: String, length: Int, flags: UInt16, value: Data, valueOffset: Int) {
            self.name = name
            self.length = length
            self.flags = flags
            self.value = value
            self.valueOffset = valueOffset
        }
    }

    /// A node in the device tree containing properties and child nodes.
    final class DTNode {
        var properties: [DTProperty] = []
        var children: [DTNode] = []
    }

    // MARK: - Init

    public init(data: Data, verbose: Bool = true) {
        buffer = BinaryBuffer(data)
        self.verbose = verbose
    }

    // MARK: - Patcher

    public func findAll() throws -> [PatchRecord] {
        patches = []
        rebuiltData = nil
        let root = try parsePayload(buffer.data)
        try applyPatches(root: root)
        rebuiltData = serializePayload(root)
        return patches
    }

    @discardableResult
    public func apply() throws -> Int {
        if patches.isEmpty, rebuiltData == nil {
            let _ = try findAll()
        }
        if let rebuiltData {
            buffer.data = rebuiltData
        } else {
            for record in patches {
                buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
            }
        }
        if verbose, !patches.isEmpty {
            print("\n  [\(patches.count) DeviceTree patch(es) applied]")
        }
        return patches.count
    }

    public var patchedData: Data {
        rebuiltData ?? buffer.data
    }

    // MARK: - Parsing

    /// Align a value up to the next 4-byte boundary.
    private static func align4(_ n: Int) -> Int {
        (n + 3) & ~3
    }

    /// Decode a null-terminated C string from raw bytes.
    private static func decodeCString(_ data: Data) -> String {
        if let nullIndex = data.firstIndex(of: 0) {
            let slice = data[data.startIndex ..< nullIndex]
            return String(bytes: slice, encoding: .utf8) ?? ""
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Parse a device tree node from the flat binary at the given offset.
    /// Returns the parsed node and the offset past the end of the node.
    private func parseNode(_ blob: Data, offset: Int) throws -> (DTNode, Int) {
        guard offset + 8 <= blob.count else {
            throw PatcherError.invalidFormat("DeviceTree: truncated node header at offset \(offset)")
        }

        let nProps = blob.loadLE(UInt32.self, at: offset)
        let nChildren = blob.loadLE(UInt32.self, at: offset + 4)
        var pos = offset + 8

        let node = DTNode()

        for _ in 0 ..< nProps {
            guard pos + 36 <= blob.count else {
                throw PatcherError.invalidFormat("DeviceTree: truncated property header at offset \(pos)")
            }

            let nameData = blob[blob.startIndex.advanced(by: pos) ..< blob.startIndex.advanced(by: pos + 32)]
            let name = Self.decodeCString(Data(nameData))
            let length = Int(blob.loadLE(UInt16.self, at: pos + 32))
            let flags = blob.loadLE(UInt16.self, at: pos + 34)
            pos += 36

            guard pos + length <= blob.count else {
                throw PatcherError.invalidFormat("DeviceTree: truncated property value '\(name)' at offset \(pos)")
            }

            let value = Data(blob[blob.startIndex.advanced(by: pos) ..< blob.startIndex.advanced(by: pos + length)])
            let valueOffset = pos
            pos += Self.align4(length)

            node.properties.append(DTProperty(
                name: name, length: length, flags: flags,
                value: value, valueOffset: valueOffset
            ))
        }

        for _ in 0 ..< nChildren {
            let (child, nextPos) = try parseNode(blob, offset: pos)
            node.children.append(child)
            pos = nextPos
        }

        return (node, pos)
    }

    /// Parse the entire device tree payload.
    private func parsePayload(_ blob: Data) throws -> DTNode {
        let (root, end) = try parseNode(blob, offset: 0)
        guard end == blob.count else {
            throw PatcherError.invalidFormat(
                "DeviceTree: unexpected trailing bytes (\(blob.count - end) extra)"
            )
        }
        return root
    }

    private func serializeNode(_ node: DTNode) -> Data {
        var out = Data()
        out.append(contentsOf: withUnsafeBytes(of: UInt32(node.properties.count).littleEndian) { Data($0) })
        out.append(contentsOf: withUnsafeBytes(of: UInt32(node.children.count).littleEndian) { Data($0) })

        for prop in node.properties {
            var name = Data(prop.name.utf8)
            if name.count >= 32 {
                name = Data(name.prefix(31))
            }
            name.append(contentsOf: [UInt8](repeating: 0, count: 32 - name.count))
            out.append(name)

            out.append(contentsOf: withUnsafeBytes(of: UInt16(prop.length).littleEndian) { Data($0) })
            out.append(contentsOf: withUnsafeBytes(of: prop.flags.littleEndian) { Data($0) })
            out.append(prop.value)

            let pad = Self.align4(prop.length) - prop.length
            if pad > 0 {
                out.append(Data(repeating: 0, count: pad))
            }
        }

        for child in node.children {
            out.append(serializeNode(child))
        }
        return out
    }

    private func serializePayload(_ root: DTNode) -> Data {
        serializeNode(root)
    }

    // MARK: - Node Navigation

    /// Get the "name" property value from a node.
    private func nodeName(_ node: DTNode) -> String {
        for prop in node.properties {
            if prop.name == "name" {
                return Self.decodeCString(prop.value)
            }
        }
        return ""
    }

    /// Find a direct child node by name.
    private func findChild(_ node: DTNode, name: String) throws -> DTNode {
        for child in node.children {
            if nodeName(child) == name {
                return child
            }
        }
        throw PatcherError.patchSiteNotFound("DeviceTree: missing child node '\(name)'")
    }

    /// Resolve a node path like ["device-tree", "buttons"] from the root.
    private func resolveNode(_ root: DTNode, path: [String]) throws -> DTNode {
        guard !path.isEmpty, path[0] == "device-tree" else {
            throw PatcherError.patchSiteNotFound("DeviceTree: invalid node path \(path)")
        }
        var node = root
        for name in path.dropFirst() {
            node = try findChild(node, name: name)
        }
        return node
    }

    /// Find a property by name within a node.
    private func findProperty(_ node: DTNode, name: String) throws -> DTProperty {
        for prop in node.properties {
            if prop.name == name {
                return prop
            }
        }
        throw PatcherError.patchSiteNotFound("DeviceTree: missing property '\(name)'")
    }

    // MARK: - Value Encoding

    /// Encode a string value with null termination, padded/truncated to a fixed length.
    private static func encodeFixedString(_ text: String, length: Int) -> Data {
        var raw = Data(text.utf8)
        raw.append(0) // null terminator
        if raw.count > length {
            return Data(raw.prefix(length))
        }
        raw.append(contentsOf: [UInt8](repeating: 0, count: length - raw.count))
        return raw
    }

    /// Encode raw bytes for a property whose layout the caller has prepared
    /// (typically a multi-string NUL-delimited blob like `compatible`).
    /// Truncates if longer than the slot, pads with NULs if shorter.
    private static func encodeFixedBytes(_ data: Data, length: Int) -> Data {
        if data.count > length {
            return Data(data.prefix(length))
        }
        var out = Data(data)
        out.append(contentsOf: [UInt8](repeating: 0, count: length - out.count))
        return out
    }

    /// Encode an integer value as little-endian bytes.
    private static func encodeInteger(_ value: UInt64, length: Int) throws -> Data {
        var data = Data(count: length)
        switch length {
        case 1:
            data[0] = UInt8(value & 0xFF)
        case 2:
            let v = UInt16(value & 0xFFFF)
            data.withUnsafeMutableBytes { $0.storeBytes(of: v.littleEndian, as: UInt16.self) }
        case 4:
            let v = UInt32(value & 0xFFFF_FFFF)
            data.withUnsafeMutableBytes { $0.storeBytes(of: v.littleEndian, as: UInt32.self) }
        case 8:
            data.withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, as: UInt64.self) }
        default:
            throw PatcherError.invalidFormat("DeviceTree: unsupported integer length \(length)")
        }
        return data
    }

    // MARK: - Patch Application

    /// Apply the iPad profile to every firmware variant.
    private func applyPatches(root: DTNode) throws {
        let patchesToApply = Self.basePropertyPatches
        for patch in patchesToApply {
            let node = try resolveNode(root, path: patch.nodePath)
            let prop: DTProperty
            if let existing = node.properties.first(where: { $0.name == patch.property }) {
                prop = existing
            } else {
                prop = DTProperty(name: patch.property, length: 0, flags: 0, value: Data(), valueOffset: 0)
                node.properties.append(prop)
            }

            let originalBytes = Data(prop.value.prefix(patch.length))

            let newValue: Data = switch patch.value {
            case let .string(s):
                Self.encodeFixedString(s, length: patch.length)
            case let .integer(v):
                try Self.encodeInteger(v, length: patch.length)
            case let .bytes(d):
                Self.encodeFixedBytes(d, length: patch.length)
            }

            prop.length = patch.length
            prop.flags = patch.flags
            prop.value = newValue

            let record = PatchRecord(
                patchID: patch.patchID,
                component: component,
                fileOffset: prop.valueOffset,
                virtualAddress: nil,
                originalBytes: originalBytes,
                patchedBytes: newValue,
                description: patch.description
            )
            patches.append(record)

            if verbose {
                print(String(format: "  0x%06X: %@ → %@  [%@]",
                             prop.valueOffset,
                             originalBytes.hex,
                             newValue.hex,
                             patch.patchID))
            }
        }

        let product = try resolveNode(root, path: ["device-tree", "product"])
        let originalProductProperties = Dictionary(
            product.properties.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }
        )
        product.properties = try Self.iPadProductProperties.map { spec in
            let value: Data = switch spec.value {
            case let .string(text):
                Self.encodeFixedString(text, length: spec.length)
            case let .integer(number):
                try Self.encodeInteger(number, length: spec.length)
            case let .bytes(bytes):
                Self.encodeFixedBytes(bytes, length: spec.length)
            }
            let previous = originalProductProperties[spec.name]
            patches.append(PatchRecord(
                patchID: "devicetree.ipad.product.\(spec.name)",
                component: component,
                fileOffset: previous?.valueOffset ?? 0,
                virtualAddress: nil,
                originalBytes: previous?.value ?? Data(),
                patchedBytes: value,
                description: "Set /product/\(spec.name) from J607AP reference"
            ))
            return DTProperty(name: spec.name, length: spec.length, flags: spec.flags,
                              value: value, valueOffset: previous?.valueOffset ?? 0)
        }
        if let buttons = try? resolveNode(root, path: ["device-tree", "buttons"]) {
            buttons.properties.removeAll { $0.name == "home-button-type" }
        }
        // An EXP firmware may already contain iPhone capability nodes.
        product.children.removeAll { ["camera", "facetime", "audio", "iopm"].contains(nodeName($0)) }
        for nodeAdd in Self.iPadNodeAdditions {
            try applyNodeAddition(root: root, patch: nodeAdd)
        }
    }

    /// Apply a single `AddChildNodePatch`: construct the new `DTNode`,
    /// fill its `name` + caller-supplied properties, attach to the
    /// parent's `children`, and record a `PatchRecord` for the change.
    ///
    /// Skips if a child with the same name already exists under the
    /// parent — keeps the patch idempotent so re-runs against an
    /// already-patched DT don't double-add.
    private func applyNodeAddition(root: DTNode, patch: AddChildNodePatch) throws {
        let parent = try resolveNode(root, path: patch.parentPath)

        for existing in parent.children {
            if nodeName(existing) == patch.nodeName {
                if verbose {
                    print("  -      : /\(patch.parentPath.joined(separator: "/"))/\(patch.nodeName) already present, skipping  [\(patch.patchID)]")
                }
                return
            }
        }

        let newNode = DTNode()

        // The `name` property is mandatory and matches the conventional
        // shape of every other DT node — fixed length = strlen(name)+1.
        let nameValue = Self.encodeFixedString(patch.nodeName, length: patch.nodeName.utf8.count + 1)
        newNode.properties.append(DTProperty(
            name: "name",
            length: nameValue.count,
            flags: 0,
            value: nameValue,
            valueOffset: 0
        ))

        for spec in patch.properties {
            let value: Data = switch spec.value {
            case let .string(s):
                Self.encodeFixedString(s, length: spec.length)
            case let .integer(v):
                try Self.encodeInteger(v, length: spec.length)
            case let .bytes(d):
                Self.encodeFixedBytes(d, length: spec.length)
            }
            newNode.properties.append(DTProperty(
                name: spec.name,
                length: spec.length,
                flags: spec.flags,
                value: value,
                valueOffset: 0
            ))
        }

        parent.children.append(newNode)

        // Serialize the new node so the patch record carries the bytes
        // we conceptually added. fileOffset = 0 because the rebuilt
        // payload is what actually lands on disk (apply() prefers
        // `rebuiltData` over per-record byte writes).
        let serialized = serializeNode(newNode)
        patches.append(PatchRecord(
            patchID: patch.patchID,
            component: component,
            fileOffset: 0,
            virtualAddress: nil,
            originalBytes: Data(),
            patchedBytes: serialized,
            description: patch.description
        ))

        if verbose {
            print("  +node  : /\(patch.parentPath.joined(separator: "/"))/\(patch.nodeName)  (\(newNode.properties.count) props, \(serialized.count)B)  [\(patch.patchID)]")
        }
    }
}
