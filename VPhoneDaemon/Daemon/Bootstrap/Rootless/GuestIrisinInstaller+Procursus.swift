import ArchiveKit
import Darwin
import Foundation
import IcliKit

// MARK: - Procursus rootless bootstrap

extension GuestIrisinInstaller {
    /// Procursus publishes this rootless archive and Sileo package independently.
    /// The archive is the same `var/jb` payload used by the former JB installer.
    static let procursusArchive = URL(string: "https://apt.procurs.us/bootstraps/1900/bootstrap-iphoneos-arm64.tar.zst")!
    static let sileoPackage = URL(string: "https://apt.procurs.us/pool/main/iphoneos-arm64-rootless/3000/sileo/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb")!
    static let trollStore27Package = URL(string: "https://github.com/Xplo8E/TrollStore27/releases/download/v2.1.1-ios27.2/com.opa334.trollstorehelper27_2.1.1-ios27+2_iphoneos-arm64.deb")!

    static func installTrollStoreLite() throws -> [String: Any] {
        installLock.lock()
        defer { installLock.unlock() }
        let installed = (try? searchApps("TrollStore")["apps"] as? [[String: Any]]) ?? []
        let installedPaths = [
            "/var/jb/Applications/TrollStoreLite.app",
            "/var/jb/Applications/TrollStore.app",
            "/Applications/TrollStore.app",
            "/Applications/TrollStoreLite.app",
        ]
        if installedPaths.contains(where: isDirectory) || installed.contains(where: {
            ($0["bundle_id"] as? String ?? "").lowercased().contains("trollstore")
        }) {
            return ["already_installed": true]
        }
        guard let bootstrap = try completedBootstrap(), bootstrap.layout == "rootless",
              FileManager.default.isExecutableFile(atPath: rootlessRoot + "/usr/bin/apt-get")
        else { throw GuestAPIError.operationFailed("Install the Procursus rootless bootstrap first") }

        let os = ProcessInfo.processInfo.operatingSystemVersion
        if os.majorVersion >= 27 {
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("vphoned-trollstore-\(UUID().uuidString).deb")
            defer { try? FileManager.default.removeItem(at: work) }
            try fetch(trollStore27Package).write(to: work)
            let metadata = try readDeb(work.path)["control"] as? [String: String] ?? [:]
            guard metadata["Package"] == "com.opa334.trollstorehelper27",
                  metadata["Architecture"] == "iphoneos-arm64"
            else { throw GuestAPIError.operationFailed("TrollStore Lite package has unexpected metadata") }
            try runProcursusTool(rootlessRoot + "/usr/bin/apt-get", ["update", "-qq"])
            try runProcursusTool(rootlessRoot + "/usr/bin/apt-get", ["install", "-y", "ldid"])
            try runProcursusTool(rootlessRoot + "/usr/bin/apt-get", ["install", "-y", work.path])
        } else {
            let source = URL(fileURLWithPath: rootlessRoot + "/etc/apt/sources.list.d/havoc.list")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if !itemExists(source) {
                try "deb https://havoc.app/ ./\n".write(to: source, atomically: true, encoding: .utf8)
            }
            try runProcursusTool(rootlessRoot + "/usr/bin/apt-get", ["update", "-qq"])
            try runProcursusTool(rootlessRoot + "/usr/bin/apt-get",
                                 ["install", "-y", "com.opa334.trollstorelite"])
        }
        let app = rootlessRoot + "/Applications/TrollStoreLite.app"
        guard isDirectory(app) else {
            throw GuestAPIError.operationFailed("TrollStore Lite package installed without its app")
        }
        let registration = try registerApp(app)
        return ["already_installed": false, "app_path": app, "registration": registration]
    }

    static func installProcursus(jailbreak: [String: Any]) throws -> [String: Any] {
        if let layout = jailbreak["layout"] as? String, layout != "rootless" {
            throw GuestAPIError.invalidRequest("The guest already uses a \(layout) bootstrap")
        }
        guard !itemExists(URL(fileURLWithPath: rootlessRoot)) else {
            throw GuestAPIError.operationFailed("/var/jb already exists; inspect or remove that environment first")
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphoned-procursus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent("bootstrap.tar.zst")
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        setProgress(["phase": "downloading", "source": "procursus", "layout": "rootless"])
        try fetch(procursusArchive, reportDownload: true).write(to: archive)
        setProgress(["phase": "extracting", "source": "procursus", "layout": "rootless"])
        try extractProcursusArchive(archive, to: extracted)
        let payload = extracted.appendingPathComponent("var/jb", isDirectory: true)
        guard isDirectory(payload.path) else {
            throw GuestAPIError.operationFailed("Procursus archive has an unexpected layout")
        }

        // Older Procursus archives put part of the root below var/jb/jb.
        let nested = payload.appendingPathComponent("jb", isDirectory: true)
        if isDirectory(nested.path) {
            for child in try FileManager.default.contentsOfDirectory(at: nested, includingPropertiesForKeys: nil) {
                let target = payload.appendingPathComponent(child.lastPathComponent)
                guard !itemExists(target) else {
                    throw GuestAPIError.operationFailed("Procursus archive contains duplicate \(child.lastPathComponent)")
                }
                try FileManager.default.moveItem(at: child, to: target)
            }
            try FileManager.default.removeItem(at: nested)
        }
        guard FileManager.default.isExecutableFile(atPath: payload.appendingPathComponent("usr/bin/dpkg").path),
              FileManager.default.isExecutableFile(atPath: payload.appendingPathComponent("usr/bin/apt-get").path),
              itemExists(payload.appendingPathComponent("prep_bootstrap.sh"))
        else { throw GuestAPIError.operationFailed("Procursus archive is missing its package tools") }
        let preboot = URL(fileURLWithPath: "/private/preboot", isDirectory: true)
        let bootRoots = try FileManager.default.contentsOfDirectory(at: preboot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: "^[0-9A-Fa-f]{96}$", options: .regularExpression) != nil }
            .filter { isDirectory($0.appendingPathComponent("usr/standalone/firmware").path) }
        guard bootRoots.count == 1 else {
            throw GuestAPIError.operationFailed("Could not identify one active preboot volume")
        }
        let target = bootRoots[0].appendingPathComponent("jb-vphone/procursus", isDirectory: true)
        guard !itemExists(target) else {
            throw GuestAPIError.operationFailed("A Procursus environment already exists in preboot")
        }
        setProgress(["phase": "installing", "source": "procursus", "layout": "rootless"])
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: payload, to: target)
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(atPath: rootlessRoot)
                try? FileManager.default.removeItem(at: target)
            }
        }
        try FileManager.default.createSymbolicLink(atPath: rootlessRoot, withDestinationPath: target.path)

        // The Procursus launchctl in this archive references a symbol missing
        // on research guests. Keep it for inspection and use the system tool.
        let launchctl = URL(fileURLWithPath: rootlessRoot + "/usr/bin/launchctl")
        let originalLaunchctl = URL(fileURLWithPath: rootlessRoot + "/usr/bin/launchctl.procursus")
        if itemExists(launchctl), !itemExists(originalLaunchctl) {
            try FileManager.default.moveItem(at: launchctl, to: originalLaunchctl)
        }
        if !itemExists(launchctl) {
            try FileManager.default.createSymbolicLink(atPath: launchctl.path, withDestinationPath: "/bin/launchctl")
        }

        let mobileLibrary = URL(fileURLWithPath: rootlessRoot + "/var/mobile/Library", isDirectory: true)
        try FileManager.default.createDirectory(at: mobileLibrary.appendingPathComponent("Preferences"),
                                                withIntermediateDirectories: true)
        guard let entries = FileManager.default.enumerator(at: mobileLibrary,
            includingPropertiesForKeys: nil, options: []) else {
            throw GuestAPIError.operationFailed("Could not inspect Procursus mobile Library")
        }
        for entry in [mobileLibrary] + entries.compactMap({ $0 as? URL }) {
            guard lchown(entry.path, 501, 501) == 0 else {
                throw GuestAPIError.operationFailed("Could not assign Procursus mobile Library to mobile")
            }
        }

        try runProcursusTool("/bin/sh", [rootlessRoot + "/prep_bootstrap.sh"])
        let firmware = try ensureFirmwareRecord(root: rootlessRoot)
        for name in [".procursus_strapped", ".installed_dopamine"] {
            let marker = rootlessRoot + "/" + name
            if !itemExists(URL(fileURLWithPath: marker)) {
                FileManager.default.createFile(atPath: marker, contents: Data())
            }
        }
        let sileo = work.appendingPathComponent("Sileo.deb")
        setProgress(["phase": "downloading", "source": "procursus", "layout": "rootless", "package": "sileo"])
        try fetch(sileoPackage, reportDownload: true).write(to: sileo)
        let metadata = try readDeb(sileo.path)["control"] as? [String: String] ?? [:]
        guard metadata["Package"] == "org.coolstar.sileo",
              metadata["Architecture"] == "iphoneos-arm64"
        else { throw GuestAPIError.operationFailed("Downloaded Sileo package has unexpected metadata") }
        setProgress(["phase": "installing", "source": "procursus", "layout": "rootless", "package": "sileo"])
        try runProcursusTool(rootlessRoot + "/usr/bin/dpkg", ["-i", sileo.path])
        let app = rootlessRoot + "/Applications/Sileo.app"
        guard isDirectory(app) else { throw GuestAPIError.operationFailed("Sileo was not installed") }
        let registration = try registerApp(app)
        try writeMarker(["source": "procursus", "layout": "rootless", "jbroot": rootlessRoot])
        completed = true
        loadBootstrapDaemons(layout: "rootless", root: rootlessRoot)
        return ["source": "procursus", "layout": "rootless", "jbroot": rootlessRoot,
                "version": metadata["Version"] ?? "", "app_path": app,
                "registration": registration, "firmware_version": firmware.version]
    }

    /// libarchive is already part of the guest's package reader. Rebase every
    /// archive path into a fresh directory and reject traversal before writing.
    static func extractProcursusArchive(_ archive: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let reader = archive_read_new() else {
            throw GuestAPIError.operationFailed("Could not create Procursus archive reader")
        }
        defer { archive_read_free(reader) }
        archive_read_support_filter_all(reader)
        archive_read_support_format_tar(reader)
        guard archive_read_open_filename(reader, archive.path, 65_536) == ARCHIVE_OK else {
            throw GuestAPIError.operationFailed("Could not open Procursus archive")
        }
        var entry: OpaquePointer?
        while archive_read_next_header(reader, &entry) == ARCHIVE_OK {
            guard let entry, let raw = archive_entry_pathname(entry).map({ String(cString: $0) }) else {
                throw GuestAPIError.operationFailed("Procursus archive has an invalid entry")
            }
            if raw == "." || raw == "./" {
                archive_read_data_skip(reader)
                continue
            }
            let relative = raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
            let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
            guard !relative.hasPrefix("/"), !parts.isEmpty,
                  parts.allSatisfy({ $0 != "." && $0 != ".." }),
                  parts.first == "var",
                  (parts.count == 1 && archive_entry_filetype(entry) == S_IFDIR)
                    || parts.dropFirst().first == "jb" else {
                throw GuestAPIError.operationFailed("Procursus archive contains an unexpected path: \(raw)")
            }
            let target = destination.appendingPathComponent(parts.joined(separator: "/")).path
            archive_entry_set_pathname(entry, target)
            if let link = archive_entry_hardlink(entry) {
                let path = String(cString: link)
                let linkParts = path.split(separator: "/", omittingEmptySubsequences: true)
                guard !path.hasPrefix("/"), linkParts.first == "var",
                      linkParts.dropFirst().first == "jb",
                      linkParts.allSatisfy({ $0 != "." && $0 != ".." }) else {
                    throw GuestAPIError.operationFailed("Procursus archive has an unsafe hard link")
                }
                archive_entry_set_hardlink(entry, destination.appendingPathComponent(linkParts.joined(separator: "/")).path)
            }
            let flags = Int32(ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_SECURE_SYMLINKS)
            guard archive_read_extract(reader, entry, flags) == ARCHIVE_OK else {
                throw GuestAPIError.operationFailed("Could not extract Procursus entry: \(raw)")
            }
        }
        guard archive_errno(reader) == 0 else {
            throw GuestAPIError.operationFailed("Procursus archive is incomplete")
        }
    }

    static func runProcursusTool(_ path: String, _ arguments: [String]) throws {
        let values = [path] + arguments
        var argv = values.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let environment = [
            "PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME=/var/root", "NO_PASSWORD_PROMPT=1", "JBROOT=/var/jb",
        ]
        var envp = environment.map { strdup($0) } + [nil]
        defer { envp.forEach { free($0) } }
        var outputPipe: [Int32] = [0, 0]
        guard pipe(&outputPipe) == 0 else {
            throw GuestAPIError.operationFailed("Could not capture package tool output")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, outputPipe[0])
        posix_spawn_file_actions_addclose(&actions, outputPipe[1])
        var pid: pid_t = 0
        let started = posix_spawn(&pid, path, &actions, nil, &argv, &envp)
        posix_spawn_file_actions_destroy(&actions)
        close(outputPipe[1])
        guard started == 0 else {
            close(outputPipe[0])
            throw GuestAPIError.operationFailed("Could not start \(path): \(String(cString: strerror(started)))")
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(outputPipe[0], &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            output.append(contentsOf: buffer.prefix(count))
            if output.count > 4096 { output.removeFirst(output.count - 4096) }
        }
        close(outputPipe[0])
        var status: Int32 = 0
        var waited = waitpid(pid, &status, 0)
        while waited < 0 && errno == EINTR { waited = waitpid(pid, &status, 0) }
        guard waited == pid, status == 0 else {
            let details = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GuestAPIError.operationFailed("\(path) exited with status \(status): \(details)")
        }
    }
}
