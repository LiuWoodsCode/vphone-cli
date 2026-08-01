import AppKit
import Foundation
import IOKit.ps
import ImageIO

// MARK: - Host Control Socket

/// Unix domain socket API for external programs.
///
/// Requests and responses are newline-delimited JSON. A connection may carry
/// more than one request. Guest commands use the same `t` values as
/// VPhoneControl/vphoned, so the socket remains useful to scripts without
/// requiring an MCP-specific adapter.
///
/// Screenshots are deliberately opt-in for normal commands:
///   {"t":"tap","x":645,"y":1398,"screen":true}
///
/// The screenshot command returns a compact base64 JPEG by default. Binary
/// guest responses (for example file_get) are returned as base64 in `data`.
@MainActor
class VPhoneHostControl {
    private let socketPath: String
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "vphone.hostcontrol.accept")

    private weak var captureView: VPhoneVirtualMachineView?
    private var screenRecorder: VPhoneScreenRecorder?
    private weak var control: VPhoneControl?
    private weak var vm: VPhoneVirtualMachine?

    private var batterySyncEnabled = false
    private var guestBatteryCharge = 100.0
    private var guestBatteryConnectivity = 1

    /// Thread-safe box for passing results between the main actor and socket queues.
    private final class ResultBox: @unchecked Sendable {
        var response: [String: Any]?
        var data: Data?
        var error: String?
        var imageBase64: String?
        var done = false
    }

    /// JSONSerialization produces `[String: Any]`, which is intentionally not
    /// Sendable. This box marks an immutable request snapshot for the socket
    /// queue -> main-actor hop.
    private final class JSONBox: @unchecked Sendable {
        let value: [String: Any]

        init(_ value: [String: Any]) {
            self.value = value
        }
    }

    private var screenWidth = 1290
    private var screenHeight = 2796
    private static let compactScale = 3

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start(
        captureView: VPhoneVirtualMachineView?,
        screenRecorder: VPhoneScreenRecorder?,
        control: VPhoneControl,
        screenWidth: Int,
        screenHeight: Int,
        vm: VPhoneVirtualMachine? = nil
    ) {
        self.captureView = captureView
        self.screenRecorder = screenRecorder
        self.control = control
        self.vm = vm
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight

        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[hostctl] failed to create socket: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            print("[hostctl] socket path too long")
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for (index, byte) in pathBytes.enumerated() {
                    dst[index] = byte
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("[hostctl] bind failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        guard listen(fd, 16) == 0 else {
            print("[hostctl] listen failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listenFD = fd
        print("[hostctl] listening on \(socketPath)")

        acceptQueue.async { [weak self] in
            Self.acceptLoop(listenFD: fd, controller: self)
        }
    }

    func stop() {
        if listenFD >= 0 {
            _ = Darwin.shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    // MARK: - Screenshot

    private func captureCompactScreenshot() async -> String? {
        guard let recorder = screenRecorder, let view = captureView, view.window != nil,
              let cgImage = await captureStillImage(recorder: recorder, view: view)
        else { return nil }

        let dstW = max(cgImage.width / Self.compactScale, 1)
        let dstH = max(cgImage.height / Self.compactScale, 1)
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: dstW, height: dstH, bitsPerComponent: 8,
            bytesPerRow: dstW, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        guard let grayImage = ctx.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, grayImage,
            [kCGImageDestinationLossyCompressionQuality: 0.35] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data).base64EncodedString()
    }

    private func captureStillImage(recorder: VPhoneScreenRecorder, view: NSView) async -> CGImage? {
        guard let vmView = view as? VPhoneVirtualMachineView,
              let display = vmView.recordingGraphicsDisplay
        else { return nil }

        return await withCheckedContinuation { continuation in
            let selector = NSSelectorFromString("_takeScreenshotWithCompletionHandler:")
            guard display.responds(to: selector),
                  let cls = object_getClass(display),
                  let method = class_getInstanceMethod(cls, selector)
            else {
                continuation.resume(returning: nil)
                return
            }

            typealias CompletionBlock = @convention(block) (AnyObject?) -> Void
            typealias IMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            let implementation = method_getImplementation(method)
            let function = unsafeBitCast(implementation, to: IMP.self)
            let block: CompletionBlock = { imageObject in
                guard let imageObject else {
                    continuation.resume(returning: nil)
                    return
                }
                if let image = imageObject as? NSImage {
                    continuation.resume(returning: image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                    return
                }
                let cf = imageObject as CFTypeRef
                continuation.resume(returning: CFGetTypeID(cf) == CGImage.typeID ? (cf as! CGImage) : nil)
            }
            function(display, selector, unsafeBitCast(block, to: AnyObject.self))
        }
    }

    // MARK: - Socket Dispatch

    private nonisolated static func acceptLoop(listenFD: Int32, controller: VPhoneHostControl?) {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { break }
            DispatchQueue.global(qos: .userInitiated).async {
                handleClient(clientFD, controller: controller)
            }
        }
    }

    private nonisolated static func handleClient(_ fd: Int32, controller: VPhoneHostControl?) {
        defer { close(fd) }
        let reader = LineReader()

        while let line = reader.readLine(from: fd, maxLength: 16 * 1024 * 1024) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["t"] as? String
            else {
                writeResponse(fd, payload: ["ok": false, "error": "invalid JSON"])
                continue
            }

            let requestID = json["id"] as? String
            let wantScreen = json["screen"] as? Bool ?? (type == "screenshot")
            let screenDelay = max(number(json["delay"]) ?? 500, 0)
            let result = ResultBox()

            switch type {
            case "screenshot":
                let screenshotPath = json["path"] as? String
                Task { @MainActor in
                    guard let controller, let recorder = controller.screenRecorder,
                          let view = controller.captureView, view.window != nil
                    else {
                        result.error = "no active VM view"
                        result.done = true
                        return
                    }
                    defer { result.done = true }
                    do {
                        if let path = screenshotPath {
                            let url = try await recorder.saveScreenshot(
                                view: view, to: URL(fileURLWithPath: path)
                            )
                            result.response = ["ok": true, "path": url.path]
                        } else {
                            result.response = ["ok": true]
                        }
                        result.imageBase64 = await controller.captureCompactScreenshot()
                    } catch {
                        result.error = "\(error)"
                    }
                }
                waitFor(result)

            case "tap":
                guard let x = number(json["x"]), let y = number(json["y"]) else {
                    result.error = "tap requires x and y (pixel coordinates)"
                    result.done = true
                    break
                }
                Task { @MainActor in
                    defer { result.done = true }
                    guard let controller, let view = controller.captureView, view.window != nil else {
                        result.error = "no active VM view"
                        return
                    }
                    view.injectTap(
                        pixelX: x, pixelY: y,
                        screenWidth: controller.screenWidth, screenHeight: controller.screenHeight
                    )
                    result.response = ["ok": true]
                    await controller.captureAfterDelay(
                        wantScreen: wantScreen, delay: screenDelay, result: result
                    )
                }
                waitFor(result)

            case "swipe":
                guard let x1 = number(json["x1"]), let y1 = number(json["y1"]),
                      let x2 = number(json["x2"]), let y2 = number(json["y2"]) else {
                    result.error = "swipe requires x1, y1, x2, y2"
                    result.done = true
                    break
                }
                let duration = max(number(json["ms"]) ?? 300, 0)
                Task { @MainActor in
                    defer { result.done = true }
                    guard let controller, let view = controller.captureView, view.window != nil else {
                        result.error = "no active VM view"
                        return
                    }
                    view.injectSwipe(
                        fromX: x1, fromY: y1, toX: x2, toY: y2,
                        screenWidth: controller.screenWidth, screenHeight: controller.screenHeight,
                        durationMs: Int(duration)
                    )
                    result.response = ["ok": true]
                    await controller.captureAfterDelay(
                        wantScreen: wantScreen, delay: duration + screenDelay, result: result
                    )
                }
                waitFor(result)

            case "key", "key_down", "key_up":
                guard let key = hidKey(json["name"] as? String) else {
                    result.error = "unknown key (home, power, volup, voldown)"
                    result.done = true
                    break
                }
                var request: [String: Any] = ["t": "hid", "page": key.page, "usage": key.usage]
                if type == "key_down" { request["down"] = true }
                if type == "key_up" { request["down"] = false }
                if type == "key", let down = json["down"] as? Bool { request["down"] = down }
                forwardGuest(request, controller: controller, result: result,
                             wantScreen: wantScreen, screenDelay: screenDelay)
                waitFor(result)

            case "battery", "battery_status", "battery_set", "battery_level",
                 "battery_connectivity", "battery_sync":
                let jsonBox = JSONBox(json)
                Task { @MainActor in
                    guard let controller else {
                        result.error = "host controller unavailable"
                        result.done = true
                        return
                    }
                    controller.handleBatteryCommand(type: type, json: jsonBox.value, result: result)
                }
                waitFor(result)

            case "file_put":
                handleFilePut(json, controller: controller, result: result)
                waitFor(result)

            case "file_get":
                forwardGuest(json, controller: controller, result: result,
                             wantScreen: wantScreen, screenDelay: screenDelay)
                waitFor(result)

            case "clipboard_set" where json["image_base64"] != nil:
                handleClipboardImage(json, controller: controller, result: result)
                waitFor(result)

            case "ipa_install" where json["host_path"] != nil || json["path"] != nil:
                handleIPAInstall(json, controller: controller, result: result)
                waitFor(result)

            default:
                // This covers all current VPhoneControl guest operations:
                // location, settings, keychain, apps, URL, accessibility,
                // clipboard, devmode, low power mode, HID and touch.
                forwardGuest(json, controller: controller, result: result,
                             wantScreen: wantScreen, screenDelay: screenDelay)
                waitFor(result)
            }

            var payload = result.response ?? ["ok": result.error == nil]
            if let error = result.error {
                payload = ["ok": false, "error": error]
            }
            if let data = result.data {
                payload["data"] = data.base64EncodedString()
                payload["encoding"] = "base64"
                payload["size"] = data.count
            }
            if let image = result.imageBase64 { payload["image"] = image }
            writeResponse(fd, payload: payload, requestID: requestID)
        }
    }

    private nonisolated static func forwardGuest(
        _ request: [String: Any], controller: VPhoneHostControl?,
        result: ResultBox, wantScreen: Bool, screenDelay: Double
    ) {
        let requestBox = JSONBox(request)
        Task { @MainActor in
            defer { result.done = true }
            guard let controller, let control = controller.control, control.isConnected else {
                result.error = "guest not connected"
                return
            }
            do {
                let (response, data) = try await control.sendRequest(requestBox.value)
                result.response = response
                result.data = data
                await controller.captureAfterDelay(
                    wantScreen: wantScreen, delay: screenDelay, result: result
                )
            } catch {
                result.error = "\(error)"
            }
        }
    }

    private nonisolated static func handleFilePut(
        _ json: [String: Any], controller: VPhoneHostControl?, result: ResultBox
    ) {
        guard let path = json["path"] as? String else {
            result.error = "file_put requires path"
            result.done = true
            return
        }
        guard let encoded = json["data"] as? String,
              let data = Data(base64Encoded: encoded) else {
            result.error = "file_put requires base64 data"
            result.done = true
            return
        }
        let permissions = json["perm"] as? String ?? "644"
        Task { @MainActor in
            defer { result.done = true }
            guard let control = controller?.control, control.isConnected else {
                result.error = "guest not connected"
                return
            }
            do {
                try await control.uploadFile(path: path, data: data, permissions: permissions)
                result.response = ["ok": true, "path": path, "size": data.count]
            } catch {
                result.error = "\(error)"
            }
        }
    }

    private nonisolated static func handleClipboardImage(
        _ json: [String: Any], controller: VPhoneHostControl?, result: ResultBox
    ) {
        guard let encoded = json["image_base64"] as? String,
              let data = Data(base64Encoded: encoded) else {
            result.error = "clipboard_set image_base64 is not valid base64"
            result.done = true
            return
        }
        Task { @MainActor in
            defer { result.done = true }
            guard let control = controller?.control, control.isConnected else {
                result.error = "guest not connected"
                return
            }
            do {
                try await control.clipboardSet(imageData: data)
                result.response = ["ok": true]
            } catch {
                result.error = "\(error)"
            }
        }
    }

    private nonisolated static func handleIPAInstall(
        _ json: [String: Any], controller: VPhoneHostControl?, result: ResultBox
    ) {
        let hostPath = (json["host_path"] as? String) ?? (json["path"] as? String)
        guard let hostPath, FileManager.default.fileExists(atPath: hostPath) else {
            // A remote ipa_install request is still supported by the generic
            // guest bridge when the path is not a host file.
            forwardGuest(json, controller: controller, result: result,
                         wantScreen: false, screenDelay: 0)
            return
        }
        Task { @MainActor in
            defer { result.done = true }
            guard let control = controller?.control, control.isConnected else {
                result.error = "guest not connected"
                return
            }
            do {
                let message = try await control.installIPA(localURL: URL(fileURLWithPath: hostPath))
                result.response = ["ok": true, "msg": message]
            } catch {
                result.error = "\(error)"
            }
        }
    }

    // MARK: - Battery

    private func handleBatteryCommand(type: String, json: [String: Any], result: ResultBox) {
        defer { result.done = true }
        let action: String
        switch type {
        case "battery_status": action = "status"
        case "battery_set": action = "set"
        case "battery_level": action = "level"
        case "battery_connectivity": action = "connectivity"
        case "battery_sync": action = "sync"
        default: action = json["action"] as? String ?? "status"
        }

        switch action {
        case "status":
            var payload: [String: Any] = [
                "ok": true,
                "guest_charge": guestBatteryCharge,
                "guest_connectivity": guestBatteryConnectivity,
                "sync_enabled": batterySyncEnabled,
            ]
            if let host = hostBatteryState() {
                payload["host_charge"] = host.charge
                payload["host_connectivity"] = host.connectivity
            }
            payload["low_power_mode"] = ProcessInfo.processInfo.isLowPowerModeEnabled
            result.response = payload

        case "set", "level", "connectivity":
            let charge = action == "connectivity"
                ? guestBatteryCharge
                : Self.number(json["charge"] ?? json["level"]) ?? guestBatteryCharge
            guard (0...100).contains(charge) else {
                result.error = "battery charge must be between 0 and 100"
                return
            }
            let connectivity = action == "level"
                ? guestBatteryConnectivity
                : Self.batteryConnectivity(json["connectivity"] ?? json["state"]) ?? guestBatteryConnectivity
            guard connectivity == 1 || connectivity == 2 else {
                result.error = "battery connectivity must be 1/charging or 2/disconnected"
                return
            }
            guestBatteryCharge = charge
            guestBatteryConnectivity = connectivity
            vm?.setBattery(charge: charge, connectivity: connectivity)
            result.response = [
                "ok": true, "charge": charge, "connectivity": connectivity,
            ]

        case "sync":
            batterySyncEnabled = json["enabled"] as? Bool ?? true
            if batterySyncEnabled, let host = hostBatteryState() {
                guestBatteryCharge = host.charge
                guestBatteryConnectivity = host.connectivity
                vm?.setBattery(charge: host.charge, connectivity: host.connectivity)
            }
            result.response = ["ok": true, "enabled": batterySyncEnabled]

        default:
            result.error = "unknown battery action: \(action)"
        }
    }

    private func hostBatteryState() -> (charge: Double, connectivity: Int)? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                    as? [String: Any],
                  let type = info[kIOPSTypeKey as String] as? String,
                  type == kIOPSInternalBatteryType
            else { continue }
            let capacity = info[kIOPSCurrentCapacityKey as String] as? Int ?? 100
            let state = info[kIOPSPowerSourceStateKey as String] as? String ?? kIOPSACPowerValue
            return (Double(capacity), state == kIOPSACPowerValue ? 1 : 2)
        }
        return nil
    }

    // MARK: - Helpers

    private nonisolated static func waitFor(_ result: ResultBox) {
        while !result.done {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private func captureAfterDelay(wantScreen: Bool, delay: Double, result: ResultBox) async {
        if wantScreen {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000))
            result.imageBase64 = await captureCompactScreenshot()
        }
    }

    private nonisolated static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private nonisolated static func batteryConnectivity(_ value: Any?) -> Int? {
        if let number = number(value) { return Int(number) }
        switch (value as? String)?.lowercased() {
        case "charging", "connected", "ac": return 1
        case "disconnected", "not_charging", "battery": return 2
        default: return nil
        }
    }

    private nonisolated static func hidKey(_ name: String?) -> (page: UInt32, usage: UInt32)? {
        switch name?.lowercased() {
        case "home": return (0x0C, 0x40)
        case "power": return (0x0C, 0x30)
        case "volup", "volume_up": return (0x0C, 0xE9)
        case "voldown", "volume_down": return (0x0C, 0xEA)
        default: return nil
        }
    }

    private nonisolated static func writeResponse(
        _ fd: Int32, payload: [String: Any], requestID: String? = nil
    ) {
        var dict = payload
        if let requestID { dict["id"] = requestID }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        _ = line.withCString { pointer in
            writeFully(fd, buffer: UnsafeRawPointer(pointer), count: strlen(pointer))
        }
    }

    private nonisolated static func writeFully(_ fd: Int32, buffer: UnsafeRawPointer, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let written = Darwin.write(fd, buffer + offset, count - offset)
            if written <= 0 { return false }
            offset += written
        }
        return true
    }

    private final class LineReader: @unchecked Sendable {
        private var buffer = Data()

        func readLine(from fd: Int32, maxLength: Int) -> String? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    return String(data: line, encoding: .utf8)
                }
                guard buffer.count < maxLength else { return nil }
                var chunk = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(fd, &chunk, chunk.count)
                guard count > 0 else {
                    return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8)
                }
                buffer.append(contentsOf: chunk[..<count])
            }
        }
    }
}
