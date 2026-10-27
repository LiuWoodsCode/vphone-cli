import Darwin
import CryptoKit
import Foundation
import IcliKit

// MARK: - Configuration profile management

extension GuestAPI {
    static func executeManagement(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        guard method.hasPrefix("management.") else { return nil }
        try requireForce(params, "change guest management")
        guard geteuid() == 0 else { throw GuestAPIError.operationFailed("Management changes require root") }

        let profiles = try managementProfilesDirectory()
        let count: Int
        switch method {
        case "management.restore":
            count = try restoreManagement(
                from: string(params, "staging"), to: profiles,
                manifest: params["files"] as? [[String: String]] ?? [],
                directories: params["directories"] as? [String] ?? [],
            )
        case "management.remove":
            count = try removeManagement(at: profiles)
        case "management.fix_jamf":
            count = try fixJamfManagement(at: profiles)
        case "management.remove_passcode_requirements":
            count = try removePasscodeRequirements(at: profiles)
        default:
            return nil
        }
        // Reply before launchd tears down the HTTP connection. No reboot is
        // scheduled if validation or any file operation above throws.
        let reboot = method != "management.restore" || params["reboot"] as? Bool != false
        if reboot {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                do { _ = try requestReboot(userspace: false, force: true) }
                catch { NSLog("vphoned: management reboot failed: %@", String(describing: error)) }
            }
        }
        return ["changed": count, "reboot_scheduled": reboot]
    }

    /// The backup domain SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles
    /// resolves to this system-group container. Its UUID is different on each guest.
    private static func managementProfilesDirectory() throws -> URL {
        let root = URL(fileURLWithPath: "/var/containers/Shared/SystemGroup", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let matches = names.compactMap { name -> URL? in
            let container = root.appendingPathComponent(name, isDirectory: true)
            let metadata = NSDictionary(contentsOf: container.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist"))
            guard metadata?["MCMMetadataIdentifier"] as? String == "systemgroup.com.apple.configurationprofiles" else { return nil }
            return container.appendingPathComponent("Library/ConfigurationProfiles", isDirectory: true)
        }
        guard matches.count == 1, let match = matches.first else {
            throw GuestAPIError.operationFailed("Expected one configuration profiles system group; found \(matches.count)")
        }
        return match
    }

    private struct ManagementEntries {
        let files: [(URL, String)]
        let directories: [String]
    }

    private static func checkedEntries(in directory: URL) throws -> ManagementEntries {
        let manager = FileManager.default
        var enumerationError: Error?
        guard let walk = manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else {
            throw GuestAPIError.operationFailed("Cannot enumerate \(directory.path)")
        }
        var files: [(URL, String)] = []
        var directories: [String] = []
        for case let url as URL in walk {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw GuestAPIError.invalidRequest("Profile directory contains a symbolic link")
            }
            guard values.isRegularFile == true || values.isDirectory == true else {
                throw GuestAPIError.invalidRequest("Profile directory contains an unsupported entry")
            }
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            if values.isRegularFile == true {
                files.append((url, relative))
            } else {
                directories.append(relative)
            }
        }
        if let enumerationError { throw enumerationError }
        return ManagementEntries(files: files, directories: directories)
    }

    private static func restoreManagement(
        from stagingPath: String, to destination: URL,
        manifest: [[String: String]], directories: [String],
    ) throws -> Int {
        let prefix = "/var/root/Library/Caches/vphone-management/"
        guard stagingPath.hasPrefix(prefix),
              !stagingPath.dropFirst(prefix.count).contains("/"),
              UUID(uuidString: String(stagingPath.dropFirst(prefix.count))) != nil else {
            throw GuestAPIError.invalidRequest("Invalid management staging directory")
        }
        let manager = FileManager.default
        let staging = URL(fileURLWithPath: stagingPath, isDirectory: true)
        let rootValues = try staging.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw GuestAPIError.invalidRequest("Invalid management staging directory")
        }
        guard !manifest.isEmpty else { throw GuestAPIError.invalidRequest("The backup contains no configuration profile files") }
        func validRelativePath(_ path: String) -> Bool {
            !path.isEmpty && !path.hasPrefix("/") &&
                !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
        }
        guard directories.allSatisfy(validRelativePath), Set(directories).count == directories.count else {
            throw GuestAPIError.invalidRequest("Invalid or duplicate management backup directory")
        }
        var expected: [String: (String, Int)] = [:]
        for item in manifest {
            guard let path = item["path"], let hash = item["sha256"], let modeString = item["mode"],
                  validRelativePath(path), !directories.contains(path),
                  hash.count == 64, hash.allSatisfy({ $0.isHexDigit }),
                  let mode = Int(modeString, radix: 8), (0...0o7777).contains(mode),
                  expected.updateValue((hash.lowercased(), mode), forKey: path) == nil else {
                throw GuestAPIError.invalidRequest("Invalid or duplicate management file manifest entry")
            }
        }
        let stagedFiles = manifest.compactMap { item -> (URL, String)? in
            guard let path = item["path"] else { return nil }
            return (staging.appendingPathComponent(path), path)
        }
        try verifyManagementEntries(stagedFiles, against: expected)
        let parent = destination.deletingLastPathComponent()
        let next = parent.appendingPathComponent("ConfigurationProfiles.vphone-next-\(UUID().uuidString)")
        let previous = parent.appendingPathComponent("ConfigurationProfiles.vphone-previous-\(UUID().uuidString)")
        do {
            try manager.createDirectory(at: next, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            for path in directories {
                try manager.createDirectory(at: next.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            for (source, path) in stagedFiles {
                let target = next.appendingPathComponent(path)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: source, to: target)
            }
            try verifyManagementEntries(stagedFiles.map { (next.appendingPathComponent($0.1), $0.1) }, against: expected)
            // Replacing the directory removes every pre-existing profile file,
            // including files absent from this backup, in one atomic swap.
            let existed = manager.fileExists(atPath: destination.path)
            if existed { try manager.moveItem(at: destination, to: previous) }
            do { try manager.moveItem(at: next, to: destination) }
            catch {
                if existed { try? manager.moveItem(at: previous, to: destination) }
                throw error
            }
            if existed { try? manager.removeItem(at: previous) }
            try? manager.removeItem(at: staging)
        } catch {
            try? manager.removeItem(at: next)
            throw error
        }
        return stagedFiles.count
    }

    private static func verifyManagementEntries(_ files: [(URL, String)], against expected: [String: (String, Int)]) throws {
        guard Set(files.map(\.1)) == Set(expected.keys) else {
            throw GuestAPIError.invalidRequest("The backup file list is incomplete")
        }
        for (url, path) in files {
            guard let (hash, mode) = expected[path] else {
                throw GuestAPIError.invalidRequest("Unexpected management backup file")
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw GuestAPIError.invalidRequest("Management backup entry is not a regular file: \(path)")
            }
            let actualHash = sha256Hex(try Data(contentsOf: url, options: .mappedIfSafe))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let actualMode = (attributes[.posixPermissions] as? NSNumber)?.intValue
            guard actualHash == hash, actualMode == mode else {
                throw GuestAPIError.operationFailed("Management backup file differs from its source: \(path)")
            }
        }
    }

    private static func removeManagement(at profiles: URL) throws -> Int {
        let manager = FileManager.default
        // Device profiles, user profiles, and all managed preference users.
        let stores = managementStores(profiles: profiles)
        var removed = 0
        for store in stores where manager.fileExists(atPath: store.path) {
            for entry in try manager.contentsOfDirectory(at: store, includingPropertiesForKeys: nil) {
                try manager.removeItem(at: entry)
                removed += 1
            }
        }
        return removed
    }

    private static func fixJamfManagement(at profiles: URL) throws -> Int {
        let manager = FileManager.default
        let stores = managementStores(profiles: profiles)
        let old = "jamfcloud.com"
        let new = "ddlc.moe/jamf"
        let encodings: [String.Encoding] = [.utf8, .utf16BigEndian, .utf16LittleEndian]
        let pairs = encodings.compactMap { encoding -> (Data, Data)? in
            guard let a = old.data(using: encoding), let b = new.data(using: encoding), a.count == b.count else { return nil }
            return (a, b)
        }
        var changed = 0
        for store in stores where manager.fileExists(atPath: store.path) {
            for (file, _) in try checkedEntries(in: store).files where ["plist", "stub"].contains(file.pathExtension.lowercased()) {
                var data = try Data(contentsOf: file)
                var replacements = 0
                for (needle, replacement) in pairs {
                    var offset = data.startIndex
                    while offset < data.endIndex, let range = data.range(of: needle, in: offset..<data.endIndex) {
                        data.replaceSubrange(range, with: replacement)
                        offset = range.lowerBound + replacement.count
                        replacements += 1
                    }
                }
                guard replacements > 0 else { continue }
                let original = try manager.attributesOfItem(atPath: file.path)
                var attributes: [FileAttributeKey: Any] = [:]
                for key: FileAttributeKey in [.ownerAccountID, .groupOwnerAccountID, .posixPermissions] {
                    attributes[key] = original[key]
                }
                try data.write(to: file, options: .atomic)
                try manager.setAttributes(attributes, ofItemAtPath: file.path)
                changed += replacements
            }
        }
        return changed
    }

    private static let passcodePolicyKeys: Set<String> = [
        "forcePIN", "allowSimple", "requireAlphanumeric", "minLength", "minComplexChars",
        "maxPINAgeInDays", "pinHistory", "customRegex", "simplePasscodeComplexity",
        "passcodeKeyboardComplexity", "PasscodeType",
        "RequirePasscode", "RequireComplexPasscode", "RequireAlphanumericPasscode",
        "MinimumLength", "MinimumComplexCharacters", "MaximumPasscodeAgeInDays",
        "PasscodeHistory", "CustomRegex", "DevicePasswordEnabled",
        "AlphanumericDevicePasswordRequired", "MinDevicePasswordLength",
        "MinDevicePasswordComplexCharacters", "DevicePasswordExpiration",
        "DevicePasswordHistory",
    ]

    private static func removePasscodeRequirements(at profiles: URL) throws -> Int {
        let manager = FileManager.default
        var removed = 0
        for store in managementStores(profiles: profiles) where manager.fileExists(atPath: store.path) {
            for (file, _) in try checkedEntries(in: store).files {
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                var format = PropertyListSerialization.PropertyListFormat.xml
                guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) else {
                    continue
                }
                let settingsCache = ["UserSettings.plist", "MCSettingsEvents.plist"].contains(file.lastPathComponent)
                let (cleaned, count) = stripPasscodePolicy(from: plist, inRestrictions: settingsCache)
                guard count > 0 else { continue }
                guard let cleaned else {
                    try manager.removeItem(at: file)
                    removed += count
                    continue
                }
                let rewritten = try PropertyListSerialization.data(fromPropertyList: cleaned, format: format, options: 0)
                let original = try manager.attributesOfItem(atPath: file.path)
                try rewritten.write(to: file, options: .atomic)
                var attributes: [FileAttributeKey: Any] = [:]
                for key: FileAttributeKey in [.ownerAccountID, .groupOwnerAccountID, .posixPermissions] {
                    attributes[key] = original[key]
                }
                try manager.setAttributes(attributes, ofItemAtPath: file.path)
                removed += count
            }
        }
        return removed
    }

    /// Removes passcode payloads and their derived restriction caches. Other
    /// settings in the same plist, such as MDM identity and account data, stay.
    private static func stripPasscodePolicy(from value: Any, inRestrictions: Bool) -> (Any?, Int) {
        if let dictionary = value as? [String: Any] {
            if dictionary["PayloadType"] as? String == "com.apple.mobiledevice.passwordpolicy" ||
                dictionary["Type"] as? String == "com.apple.configuration.passcode.settings" {
                return (nil, 1)
            }
            let hasPasscodePolicy = dictionary.keys.contains("forcePIN") ||
                dictionary.keys.contains("RequirePasscode") || dictionary.keys.contains("DevicePasswordEnabled")
            var result: [String: Any] = [:]
            var removed = 0
            for (key, child) in dictionary {
                if key == "localizedWarning", let warning = child as? String,
                   warning.localizedCaseInsensitiveContains("passcode") {
                    removed += 1
                    continue
                }
                let isPolicyKey = passcodePolicyKeys.contains(key) &&
                    (inRestrictions || hasPasscodePolicy ||
                     key == "forcePIN" || key == "RequirePasscode" || key == "DevicePasswordEnabled" ||
                     key == "PasscodeType" ||
                     key.hasPrefix("DevicePassword") || key.hasPrefix("MinDevicePassword") ||
                     key.hasPrefix("MaxDevicePassword") || key == "AlphanumericDevicePasswordRequired" ||
                     key == "MaxInactivityTimeDeviceLock")
                if isPolicyKey {
                    removed += 1
                    continue
                }
                let nestedRestrictions = inRestrictions || ["restrictedBool", "restrictedValue", "policyValues"].contains(key)
                let (updated, count) = stripPasscodePolicy(from: child, inRestrictions: nestedRestrictions)
                removed += count
                if let updated { result[key] = updated }
            }
            return (result, removed)
        }
        if let array = value as? [Any] {
            var result: [Any] = []
            var removed = 0
            for child in array {
                let (updated, count) = stripPasscodePolicy(from: child, inRestrictions: inRestrictions)
                removed += count
                if let updated { result.append(updated) }
            }
            return (result, removed)
        }
        return (value, 0)
    }

    private static func managementStores(profiles: URL) -> [URL] {
        [profiles,
         URL(fileURLWithPath: "/var/mobile/Library/UserConfigurationProfiles", isDirectory: true),
         URL(fileURLWithPath: "/var/Managed Preferences", isDirectory: true)]
    }
}
