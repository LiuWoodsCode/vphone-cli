import CryptoKit
import Foundation
import VPhoneCoreKit

// MARK: - Configuration profile management

extension VPhoneGuestControl {
    func restoreManagement(from directory: URL, vmDirectory: URL) async throws -> Int {
        guard guestCapabilities.contains("management_manipulation") else {
            throw ControlError.unsupportedCapability("management_manipulation")
        }
        let inventory = try Self.managementBackupEntries(in: directory)
        guard !inventory.files.isEmpty else { throw ControlError.protocolError("The backup directory is empty") }
        let staging = "/var/root/Library/Caches/vphone-management/\(UUID().uuidString)"
        try await createDirectory(path: staging)
        do {
            for relative in inventory.directories {
                try await createDirectory(path: staging + "/" + relative)
            }
            var manifest: [[String: String]] = []
            for (source, relative) in inventory.files {
                let data = try Data(contentsOf: source, options: .mappedIfSafe)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                let mode = String((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644, radix: 8)
                try await uploadFile(path: staging + "/" + relative, data: data, permissions: mode)
                manifest.append(["path": relative, "sha256": hash, "mode": mode])
            }
            let result = try await call("management.restore", params: [
                "staging": staging, "files": manifest, "directories": inventory.directories,
                "force": true, "reboot": false,
            ])
            let cloud = directory.appendingPathComponent("CloudConfigurationDetails.plist")
            if FileManager.default.fileExists(atPath: cloud.path) {
                try await applyCloudConfiguration(cloud, vmDirectory: vmDirectory)
            }
            try await restartGuest()
            return result["changed"] as? Int ?? inventory.files.count
        } catch {
            try? await deleteFile(path: staging)
            throw error
        }
    }

    private func applyCloudConfiguration(_ plist: URL, vmDirectory: URL) async throws {
        let prediction = vmDirectory.appendingPathComponent("udid-prediction.txt")
        let lines = try String(contentsOf: prediction, encoding: .utf8).split(separator: "\n")
        guard let line = lines.first(where: { $0.hasPrefix("UDID=") }) else {
            throw ControlError.protocolError("The VM has no predicted USB device identifier")
        }
        let udid = String(line.dropFirst("UDID=".count))
        let cli = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("vphone-cli")
        let arguments = ["management-cloud-config", "--udid", udid, "--plist", plist.path]
        let result = try await Task.detached {
            try VPhoneProcessRunner.runCapturing(cli, arguments)
        }.value
        guard result.succeeded else {
            throw ControlError.guestError("The files were restored, but iOS refused to activate the cloud configuration: \(result.stderr)")
        }
    }

    private struct ManagementBackupInventory {
        let files: [(URL, String)]
        let directories: [String]
    }

    private static func managementBackupEntries(in directory: URL) throws -> ManagementBackupInventory {
        let manager = FileManager.default
        var enumerationError: Error?
        guard let walker = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in enumerationError = error; return false },
        ) else {
            throw ControlError.protocolError("Cannot read the backup directory")
        }
        var files: [(URL, String)] = []
        var directories: [String] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ControlError.protocolError("The backup directory contains a symbolic link")
            }
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            if values.isRegularFile == true {
                files.append((url, relative))
            } else if values.isDirectory == true {
                directories.append(relative)
            } else {
                throw ControlError.protocolError("The backup directory contains an unsupported entry")
            }
        }
        if let enumerationError { throw enumerationError }
        return ManagementBackupInventory(
            files: files.sorted { $0.1 < $1.1 },
            directories: directories.sorted(),
        )
    }

    func removeManagement() async throws -> Int {
        guard guestCapabilities.contains("management_manipulation") else {
            throw ControlError.unsupportedCapability("management_manipulation")
        }
        let result = try await call("management.remove", params: ["force": true])
        return result["changed"] as? Int ?? 0
    }

    func fixJamfUnenrollment() async throws -> Int {
        guard guestCapabilities.contains("management_manipulation") else {
            throw ControlError.unsupportedCapability("management_manipulation")
        }
        let result = try await call("management.fix_jamf", params: ["force": true])
        return result["changed"] as? Int ?? 0
    }

    func removePasscodeRequirements() async throws -> Int {
        guard guestCapabilities.contains("management_manipulation") else {
            throw ControlError.unsupportedCapability("management_manipulation")
        }
        let result = try await call("management.remove_passcode_requirements", params: ["force": true])
        return result["changed"] as? Int ?? 0
    }
}
