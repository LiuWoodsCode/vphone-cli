import Foundation
import ObjectiveC
import ParavirtualizedGraphics
import Virtualization

@main
struct GraphicsDisplaySupportTests {
    @MainActor
    static func main() throws {
        let selector = NSSelectorFromString("_maximumAllowedDisplayCount")
        let method = class_getClassMethod(VZMacGraphicsDeviceConfiguration.self, selector)!
        let original = method_getImplementation(method)
        let count = VPhoneGraphicsDisplaySupport.maximumDisplayPortCount >= 2 ? 2 : 1
        precondition(VPhoneGraphicsDisplaySupport.maximumDisplayPortCount <= Int(PGMaxDisplayPortCount()))
        precondition(method_getImplementation(method) == original, "querying capacity changed host policy")
        let graphics = VZMacGraphicsDeviceConfiguration()
        let panels = [
            VZMacGraphicsDisplayConfiguration(widthInPixels: 1398, heightInPixels: 2034, pixelsPerInch: 460),
            VZMacGraphicsDisplayConfiguration(widthInPixels: 1878, heightInPixels: 2670, pixelsPerInch: 460),
        ]
        graphics.displays = Array(panels.prefix(count))
        graphics.setValue(NSNumber(value: count), forKey: "_displayPortCount")

        // Exercise the framework validator that rejected both previous builds.
        let validateSelector = NSSelectorFromString("validateWithError:")
        let validateMethod = class_getInstanceMethod(VZMacGraphicsDeviceConfiguration.self, validateSelector)!
        typealias Validate = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
        let validate = unsafeBitCast(method_getImplementation(validateMethod), to: Validate.self)
        var error: NSError?
        precondition(validate(graphics, validateSelector, &error), "supported display configuration failed: \(String(describing: error))")

        graphics.setValue(NSNumber(value: count - 1), forKey: "_displayPortCount")
        precondition(!validate(graphics, validateSelector, &error), "the remaining port-count validation was bypassed")
        precondition(method_getImplementation(method) == original, "validation changed host policy")
        print("PASS: \(count)-panel host policy, valid configuration, and invalid port-count rejection")
    }
}
