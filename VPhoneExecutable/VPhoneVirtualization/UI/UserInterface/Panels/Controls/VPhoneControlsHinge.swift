import Foundation

/// SpringBoard's synthetic hinge states. The override API derives these
/// angles itself; it does not accept an arbitrary mechanical angle.
enum VPhoneControlsHinge: Int, CaseIterable, Identifiable {
    case closed = 1
    case partiallyOpen = 2
    case openFlat = 3

    var id: Self { self }

    var title: String {
        switch self {
        case .closed: String(localized: "Closed (0°)", bundle: VPhoneLocalization.bundle)
        case .partiallyOpen: String(localized: "Partially Open (90°)", bundle: VPhoneLocalization.bundle)
        case .openFlat: String(localized: "Open Flat (180°)", bundle: VPhoneLocalization.bundle)
        }
    }
}
