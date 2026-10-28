import Foundation

// MARK: - Fold posture RPC

extension VPhoneGuestControl {
    /// Sweeps a foldable guest to `position`, one of the three screen states
    /// Apple's Duo tooling names (`display.posture`'s `position`). `duration`
    /// is seconds — 0 an instant swap, nil the guest's per-direction default
    /// (opening faster than closing). The pose override is the primary; the
    /// virtual hinge service beside it may be off without failing the call.
    func setFoldPosition(_ position: VPhoneFoldPosition, duration: Double?) async throws -> VPhoneFoldReply {
        guard guestCapabilities.contains("device_pose") else {
            throw ControlError.unsupportedCapability("device_pose")
        }
        var params: [String: Any] = ["position": position.rawValue]
        if let duration {
            params["duration"] = duration
        }
        let result = try await call("display.posture", params: params)
        guard let angle = result.double("angle"), angle.isFinite, 0 ... 180 ~= angle,
              let hinge = result.int("hinge"), 0 ... 4 ~= hinge
        else { throw ControlError.protocolError("invalid fold posture reply") }
        let hingeHID = result.object("hinge_hid")
        let sweepMilliseconds = result.object("sweep")?.double("duration_ms")
        // Publish for the viewer's fold chrome: the angle the guest settled
        // on, and how long its sweep took so a window folds in step. The
        // guest's own default sweep answers -1 (its per-direction hand-fold
        // time, unknown here) — animate those over a similar beat; an
        // absent sweep dictionary is the legacy instant pose.
        foldSweepSeconds = sweepMilliseconds.map { $0 < 0 ? 1.2 : $0 / 1000 } ?? 0
        foldPosition = position
        foldAngle = angle
        return VPhoneFoldReply(
            position: position,
            angle: angle,
            hingeState: hinge,
            providerRunning: hingeHID?.bool("provider_running") ?? false,
            applied: hingeHID?.bool("applied") ?? false,
            sweepMilliseconds: sweepMilliseconds,
        )
    }
}
