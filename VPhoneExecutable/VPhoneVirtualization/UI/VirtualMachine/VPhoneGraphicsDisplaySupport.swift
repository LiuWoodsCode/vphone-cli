import Foundation
import ObjectiveC
import ParavirtualizedGraphics
import Virtualization

@MainActor
enum VPhoneGraphicsDisplaySupport {
    /// The VM service enforces its internal-content gate independently of
    /// client validation. Overriding the client's query only trades a useful
    /// configuration error for an opaque device-initialization failure.
    /// Honor the lower of the service policy and renderer capacity.
    static var maximumDisplayPortCount: Int {
        let selector = NSSelectorFromString("_maximumAllowedDisplayCount")
        guard let method = class_getClassMethod(VZMacGraphicsDeviceConfiguration.self, selector),
              let encoding = method_getTypeEncoding(method),
              String(cString: encoding) == "Q16@0:8"
        else { return 1 }
        typealias Maximum = @convention(c) (AnyClass, Selector) -> UInt64
        let query = unsafeBitCast(method_getImplementation(method), to: Maximum.self)
        let allowed = query(VZMacGraphicsDeviceConfiguration.self, selector)
        return Int(min(allowed, UInt64(PGMaxDisplayPortCount())))
    }
}
