@testable import FirmwarePatcher
import Foundation
import Testing

@Suite("Foldable built-in display identities")
struct CustomFirmwareFoldableDisplayTests {
    private typealias Node = FlatDeviceTreeNode
    private static let ids = ["1C896A2B-F0D7-405C-8D0F-66E4B80AD044", "BF0DC480-5EE2-4EC1-B02B-C75E94759832"]

    private static func panel(_ index: Int) -> Node {
        Node("display\(index)", [
            ("AAPL,phandle", Node.uint32(UInt32(470 + index))),
            ("display-index", Node.uint32(UInt32(index))),
            ("surface-type", Node.uint32(UInt32(index + 1))),
            ("display-rotation", Node.uint32(index == 0 ? 0 : 270)),
            ("display-scale", Node.uint32(3)),
            ("framebuffer-identifier", Data((ids[index] + "\0").utf8)),
            ("special-regions-count", Node.uint32(UInt32(index + 1))),
        ])
    }

    private static func tree(model: String = "iPhone19,4", donor: Bool, panels: [Node]? = nil) -> Data {
        Node("device-tree", [("model", Data((model + "\0").utf8))], children: [
            Node("product", [
                ("product-id", Data(repeating: donor ? 0xAB : 0x51, count: 20)),
                ("framebuffer-identifier", Data((donor ? ids[0] + "\0" : "syscfg/fbid\0").utf8)),
                ("graphics-featureset-class", Data("APPLE7\0".utf8)),
                ("has-virtualization", Node.uint32(1)),
            ], flags: donor ? [:] : ["framebuffer-identifier": 0x8000], children:
                panels ?? (donor ? [panel(0), panel(1)] : [Node("audio", [("acoustic-id", Node.uint32(42))])])),
        ]).serialized
    }

    @Test func `copies both panels without donor phandles and preserves virtual hardware`() throws {
        let original = Self.tree(donor: false)
        let board = Self.tree(donor: true)
        let (patched, changes, delta) = try CustomFirmwarePostRestoreDeviceTree.withFoldableDisplays(original, board: board)
        #expect(changes.map(\.property) == ["product/product-id", "product/framebuffer-identifier", "product/display0", "product/display1"])
        #expect(patched.count == original.count + delta)
        let parser = DeviceTreePatcher(data: patched, verbose: false)
        let root = try parser.parsePayload(patched)
        let product = try #require(root.children.first)
        #expect(product.properties.first { $0.name == "graphics-featureset-class" }?.value == Data("APPLE7\0".utf8))
        #expect(product.properties.first { $0.name == "has-virtualization" }?.value == Node.uint32(1))
        #expect(product.children.count == 3) // Existing audio plus both panels.
        for panel in product.children.dropFirst() {
            #expect(!panel.properties.contains { $0.name == "AAPL,phandle" })
        }
        let (again, noChanges, noDelta) = try CustomFirmwarePostRestoreDeviceTree.withFoldableDisplays(patched, board: board)
        #expect(again == patched && noChanges.isEmpty && noDelta == 0)
    }

    @Test func `refuses wrong boards missing panels and ambiguous display metadata`() throws {
        let original = Self.tree(donor: false)
        for board in [Self.tree(model: "iPhone17,3", donor: true),
                      Self.tree(donor: true, panels: [Self.panel(0)]),
                      Self.tree(donor: true, panels: [Self.panel(0), Self.panel(1), Self.panel(1)])] {
            #expect(throws: (any Error).self) {
                try CustomFirmwarePostRestoreDeviceTree.withFoldableDisplays(original, board: board)
            }
        }
        #expect(throws: (any Error).self) {
            try CustomFirmwarePostRestoreDeviceTree.withFoldableDisplays(Self.tree(model: "iPhone17,3", donor: false), board: Self.tree(donor: true))
        }
        var inner = Self.panel(1)
        inner.properties.append(("display-index", 0, Node.uint32(0)))
        #expect(throws: (any Error).self) {
            try CustomFirmwarePostRestoreDeviceTree.withFoldableDisplays(original, board: Self.tree(donor: true, panels: [Self.panel(0), inner]))
        }
    }
}
