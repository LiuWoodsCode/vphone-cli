import Foundation
import VPhonePatchKit

extension DeviceTreePatcher {
    /// Copy only userland display metadata, never the donor's DCP hardware.
    /// The VZ display identifier matches each node's framebuffer-identifier.
    /// Phandles belong to the source tree and must not enter the guest tree.
    static func presentFoldableDisplays(in root: DTNode, from source: DTNode) throws -> [(path: String, before: Data?, after: Data)] {
        func property(_ node: DTNode, _ key: String) throws -> DTProperty {
            let matches = node.properties.filter { $0.name == key }
            guard matches.count == 1, let value = matches.first, value.flags == 0 else {
                throw PatcherError.invalidFormat("Foldable displays: expected one concrete \(key)")
            }
            return value
        }
        func text(_ node: DTNode, _ key: String) throws -> String {
            String(decoding: try property(node, key).value.prefix { $0 != 0 }, as: UTF8.self)
        }
        func child(_ node: DTNode, _ name: String) throws -> DTNode {
            let matches = node.children.filter { (try? text($0, "name")) == name }
            guard matches.count == 1, let value = matches.first else {
                throw PatcherError.invalidFormat("Foldable displays: expected one \(name) node")
            }
            return value
        }
        let model = try text(source, "model")
        guard model == "iPhone19,4", try text(root, "model") == model else {
            throw PatcherError.invalidFormat("Foldable displays: installed and donor trees must both be iPhone19,4")
        }
        let donor = try child(source, "product")
        let product = try child(root, "product")
        let productID = try property(donor, "product-id").value
        guard productID.count == 20 else {
            throw PatcherError.invalidFormat("Foldable displays: expected a 20-byte product-id")
        }
        let panels = try (0 ... 1).map { index -> DTNode in
            let panel = try child(donor, "display\(index)")
            for (key, expected) in [("display-index", index), ("surface-type", index + 1),
                                    ("display-rotation", index == 0 ? 0 : 270), ("display-scale", 3)] {
                let bytes = try property(panel, key).value
                guard bytes.count == 4, bytes.loadLE(UInt32.self, at: 0) == UInt32(expected) else {
                    throw PatcherError.invalidFormat("Foldable displays: unexpected display\(index)/\(key)")
                }
            }
            guard UUID(uuidString: try text(panel, "framebuffer-identifier")) != nil, panel.children.isEmpty,
                  Set(panel.properties.map(\.name)).count == panel.properties.count else {
                throw PatcherError.invalidFormat("Foldable displays: invalid display\(index) metadata")
            }
            let copy = DTNode()
            copy.properties = panel.properties.filter { $0.name != "AAPL,phandle" }.map {
                DTProperty(name: $0.name, flags: $0.flags, value: $0.value, valueOffset: 0)
            }
            return copy
        }
        let identifiers = try panels.map { try text($0, "framebuffer-identifier") }
        guard Set(identifiers).count == 2, try text(donor, "framebuffer-identifier") == identifiers[0] else {
            throw PatcherError.invalidFormat("Foldable displays: panel identifiers must be distinct and outer must be primary")
        }
        // Validate the target before any mutation, so an ambiguous tree fails
        // atomically and cannot leave just one panel's metadata installed.
        for name in ["product-id", "framebuffer-identifier"] {
            guard product.properties.filter({ $0.name == name }).count <= 1 else {
                throw PatcherError.invalidFormat("Foldable displays: duplicate installed \(name)")
            }
        }
        for index in 0 ... 1 {
            guard product.children.filter({ (try? text($0, "name")) == "display\(index)" }).count <= 1 else {
                throw PatcherError.invalidFormat("Foldable displays: duplicate installed display\(index)")
            }
        }
        let parser = DeviceTreePatcher(data: Data(), verbose: false)
        var changes: [(path: String, before: Data?, after: Data)] = []
        for name in ["product-id", "framebuffer-identifier"] {
            let value = try property(donor, name).value
            let existing = product.properties.first { $0.name == name }
            if existing?.value != value || existing?.flags != 0 {
                changes.append(("product/\(name)", existing?.value, value))
                if let existing {
                    existing.value = value
                    existing.flags = 0
                } else {
                    product.properties.append(DTProperty(name: name, flags: 0, value: value, valueOffset: 0))
                }
            }
        }
        for (index, panel) in panels.enumerated() {
            let name = "display\(index)"
            let existing = product.children.firstIndex { (try? text($0, "name")) == name }
            let before = existing.map { parser.serializeNode(product.children[$0]) }
            let after = parser.serializeNode(panel)
            guard before != after else { continue }
            changes.append(("product/\(name)", before, after))
            if let existing { product.children[existing] = panel } else { product.children.append(panel) }
        }
        return changes
    }
}
