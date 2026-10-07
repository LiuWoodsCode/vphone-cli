import AppKit
import UniformTypeIdentifiers

// MARK: - Bootstrap Installation and Removal

/// Installs the selected guest package environment from the Apps menu and
/// shows vphoned's progress while it downloads and configures it.
extension VPhoneMenuController {
    /// Install and Uninstall, each with an Option alternate.
    func addBootstrapItems(to menu: NSMenu) {
        let install = makeItem(
            "Install Bootstrap…",
            action: #selector(installBootstrap),
            symbol: "arrow.down.circle",
        )
        install.isEnabled = false
        installBootstrapItem = install
        menu.addItem(install)
        let installFromFile = makeItem(
            "Install Bootstrap from File…",
            action: #selector(installBootstrapFromFile),
            modifiers: [.option],
            symbol: "doc",
        )
        installFromFile.isAlternate = true
        installFromFile.isEnabled = false
        installBootstrapFromFileItem = installFromFile
        menu.addItem(installFromFile)

        let uninstall = makeItem(
            "Uninstall Bootstrap…",
            action: #selector(uninstallBootstrap),
            symbol: "trash",
        )
        uninstall.isEnabled = false
        uninstallBootstrapItem = uninstall
        menu.addItem(uninstall)
        let uninstallNoRestart = makeItem(
            "Uninstall Bootstrap Without Restarting…",
            action: #selector(uninstallBootstrapWithoutRestart),
            modifiers: [.option],
            symbol: "trash",
        )
        uninstallNoRestart.isAlternate = true
        uninstallNoRestart.isEnabled = false
        uninstallBootstrapNoRestartItem = uninstallNoRestart
        menu.addItem(uninstallNoRestart)

        let rebuild = makeItem(
            "Rebuild App Registrations",
            action: #selector(rebuildAppRegistrations),
            symbol: "arrow.clockwise.circle",
        )
        rebuild.isEnabled = false
        rebuildAppRegistrationsItem = rebuild
        menu.addItem(rebuild)
    }

    func updateBootstrapAvailability(available: Bool) {
        let enabled = available && !isInstallingBootstrap && !isUninstallingBootstrap
        installBootstrapItem?.isEnabled = enabled
        installBootstrapFromFileItem?.isEnabled = enabled
    }

    func updateBootstrapUninstallAvailability(available: Bool) {
        let enabled = available && !isInstallingBootstrap && !isUninstallingBootstrap
        uninstallBootstrapItem?.isEnabled = enabled
        uninstallBootstrapNoRestartItem?.isEnabled = enabled
        rebuildAppRegistrationsItem?.isEnabled = enabled && !isRebuildingAppRegistrations
    }

    @objc func installBootstrap() {
        unlessBootstrapInstalled { [weak self] in
            self?.chooseBootstrapSource()
        }
    }

    private func chooseBootstrapSource() {
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28), pullsDown: false)
        picker.addItems(withTitles: [
            VPhoneLocalization.text("Procursus + Sileo (rootless)"),
            VPhoneLocalization.text("Irisin (RootHide)"),
            VPhoneLocalization.text("Irisin (rootless, deprecated)"),
        ])
        picker.selectItem(at: 0)
        picker.setAccessibilityLabel(VPhoneLocalization.text("Bootstrap environment"))

        let alert = NSAlert()
        alert.messageText = VPhoneLocalization.text("Install Bootstrap")
        alert.informativeText = VPhoneLocalization.text("Choose which package environment to install in the guest.")
        alert.accessoryView = picker
        alert.addButton(withTitle: VPhoneLocalization.text("Install"))
        alert.addButton(withTitle: VPhoneLocalization.text("Cancel"))
        VPhoneAlert.present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            switch picker.indexOfSelectedItem {
            case 0:
                self?.performBootstrapInstallation(layout: "rootless", source: "procursus", localURL: nil)
            case 1:
                self?.performBootstrapInstallation(layout: "roothide", source: "irisin", localURL: nil)
            case 2:
                self?.confirmRootlessIrisin(localURL: nil)
            default: return
            }
        }
    }

    @objc func installBootstrapFromFile() {
        unlessBootstrapInstalled { [weak self] in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [UTType(filenameExtension: "deb") ?? .data]
            panel.prompt = VPhoneLocalization.text("Install")
            panel.message = VPhoneLocalization.text("Choose an Irisin .deb package to install in the guest.")
            VPhoneAlert.present(panel) { response in
                guard response == .OK, let url = panel.url else { return }
                self?.chooseBootstrapLayout(localURL: url)
            }
        }
    }

    /// vphoned installs the bootstrap once and refuses a second install, so
    /// ask it first and explain instead of starting an install that fails.
    /// A guest that cannot be asked goes straight on; its install answer is
    /// handled the same way below.
    private func unlessBootstrapInstalled(_ proceed: @escaping @MainActor () -> Void) {
        guard !isInstallingBootstrap, !isUninstallingBootstrap else { return }
        Task {
            if let installation = await control.completedBootstrap() {
                presentBootstrapAlreadyInstalled(root: installation.root)
            } else {
                proceed()
            }
        }
    }

    private func presentBootstrapAlreadyInstalled(root: String) {
        let message = VPhoneLocalization.format(
            "The bootstrap is already installed in %@. To reinstall it, uninstall the bootstrap first.", root,
        )
        let canUninstall = control.isConnected && control.guestCapabilities.contains("bootstrap_uninstall")
        VPhoneAlert.present(
            title: "Bootstrap Already Installed",
            message: message,
            style: .informational,
            buttons: canUninstall ? ["OK", "Uninstall Bootstrap…"] : ["OK"],
        ) { [weak self] response in
            if canUninstall, response == .alertSecondButtonReturn {
                self?.uninstallBootstrap()
            }
        }
    }

    private func chooseBootstrapLayout(localURL: URL) {
        VPhoneAlert.present(
            title: "Install Irisin from File",
            message: VPhoneLocalization.format("Choose the Irisin layout for %@.", localURL.lastPathComponent),
            style: .informational,
            buttons: ["Irisin (RootHide)", "Irisin (rootless, deprecated)", "Cancel"],
        ) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.performBootstrapInstallation(layout: "roothide", localURL: localURL)
            case .alertSecondButtonReturn:
                self?.confirmRootlessIrisin(localURL: localURL)
            default: break
            }
        }
    }

    private func confirmRootlessIrisin(localURL: URL?) {
        let message = if let localURL {
            VPhoneLocalization.format(
                "%@ contains Irisin. The usual rootless environment is Procursus + Sileo. Which one do you want to install?",
                localURL.lastPathComponent,
            )
        } else {
            VPhoneLocalization.text(
                "Rootless Irisin is deprecated. The usual rootless environment is Procursus + Sileo. Which one do you want to install?",
            )
        }
        VPhoneAlert.present(
            title: "Confirm Rootless Bootstrap",
            message: message,
            style: .warning,
            buttons: ["Procursus + Sileo", "Install Irisin Rootless Anyway", "Cancel"],
        ) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.performBootstrapInstallation(layout: "rootless", source: "procursus", localURL: nil)
            case .alertSecondButtonReturn:
                self?.performBootstrapInstallation(layout: "rootless", source: "irisin", localURL: localURL)
            default: break
            }
        }
    }

    private func performBootstrapInstallation(layout: String, source: String = "irisin", localURL: URL?) {
        isInstallingBootstrap = true
        installBootstrapItem?.isEnabled = false
        installBootstrapFromFileItem?.isEnabled = false
        uninstallBootstrapItem?.isEnabled = false
        uninstallBootstrapNoRestartItem?.isEnabled = false
        rebuildAppRegistrationsItem?.isEnabled = false
        let alert = NSAlert()
        alert.messageText = VPhoneLocalization.text("Install Bootstrap")
        alert.informativeText = if let localURL {
            VPhoneLocalization.format("Installing %@ in the guest.", localURL.lastPathComponent)
        } else if source == "procursus" {
            VPhoneLocalization.text("Installing Procursus and Sileo in the guest.")
        } else {
            VPhoneLocalization.text("Installing the latest Irisin release in the guest.")
        }
        let close = alert.addButton(withTitle: VPhoneLocalization.text("Close"))
        close.isEnabled = false
        // NSAlert places the accessory 16 points from each edge; inset its
        // contents another 6 points to align with the alert's text columns.
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 132))
        let statusLabel = NSTextField(labelWithString: VPhoneLocalization.text("Preparing bootstrap…"))
        statusLabel.frame = NSRect(x: 6, y: 106, width: 348, height: 22)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        accessory.addSubview(statusLabel)
        let indicator = NSProgressIndicator(frame: NSRect(x: 6, y: 84, width: 348, height: 16))
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        accessory.addSubview(indicator)
        let detailScroll = NSTextView.scrollableTextView()
        detailScroll.frame = NSRect(x: 6, y: 4, width: 348, height: 72)
        detailScroll.isHidden = true
        let detailText = detailScroll.documentView as! NSTextView
        detailText.isEditable = false
        detailText.isSelectable = true
        detailText.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        accessory.addSubview(detailScroll)
        alert.accessoryView = accessory
        VPhoneAlert.present(alert)

        Task {
            defer {
                isInstallingBootstrap = false
                updateBootstrapAvailability(
                    available: control.isConnected && control.guestCapabilities.contains("bootstrap_install"),
                )
                updateBootstrapUninstallAvailability(
                    available: control.isConnected && control.guestCapabilities.contains("bootstrap_uninstall"),
                )
                if indicator.isIndeterminate {
                    indicator.stopAnimation(nil)
                }
                close.isEnabled = true
            }
            let poller = Task {
                while !Task.isCancelled {
                    if let status = try? await control.bootstrapStatus() {
                        updateBootstrapProgress(status, label: statusLabel, indicator: indicator)
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            do {
                let result = try await control.installBootstrap(layout: layout, source: source, localURL: localURL)
                poller.cancel()
                await poller.value
                let version = result["version"] as? String ?? ""
                let root = result["jbroot"] as? String ?? ""
                indicator.isIndeterminate = false
                indicator.minValue = 0
                indicator.maxValue = 100
                indicator.doubleValue = 100
                statusLabel.stringValue = VPhoneLocalization.text("Bootstrap installed")
                alert.informativeText = if source == "procursus" {
                    VPhoneLocalization.format("Installed Procursus and Sileo in %@.", root)
                } else if result["service_start_warning"] as? String != nil {
                    VPhoneLocalization.format(
                        "Installed Irisin %1$@ in %2$@.\n\nSome services did not start, but the bootstrap is ready to use.",
                        version,
                        root,
                    )
                } else {
                    VPhoneLocalization.format("Installed Irisin %@ in %@.", version, root)
                }
            } catch VPhoneGuestControl.ControlError.bootstrapAlreadyInstalled {
                poller.cancel()
                await poller.value
                statusLabel.stringValue = VPhoneLocalization.text("Bootstrap already installed")
                alert.informativeText = VPhoneLocalization.text(
                    "The bootstrap is already installed. To reinstall it, uninstall the bootstrap first.",
                )
            } catch {
                poller.cancel()
                await poller.value
                statusLabel.stringValue = VPhoneLocalization.text("Bootstrap installation failed")
                alert.alertStyle = .warning
                let directReason = (error as? VPhoneGuestControl.ControlError)?.description
                    ?? error.localizedDescription
                let status = try? await control.bootstrapStatus()
                let guestReason: String? = if status?["phase"] as? String == "failed",
                                              status?["layout"] as? String == layout {
                    status?["error"] as? String
                } else {
                    nil
                }
                let reason = if let guestReason, !guestReason.isEmpty, guestReason != directReason {
                    directReason + "\n\n" + guestReason
                } else {
                    directReason
                }
                detailText.string = reason
                detailScroll.isHidden = false
                alert.informativeText = VPhoneLocalization.text("Unable to install the bootstrap.")
            }
        }
    }

    @objc func uninstallBootstrap() {
        performBootstrapUninstall(reboot: true)
    }

    @objc func uninstallBootstrapWithoutRestart() {
        performBootstrapUninstall(reboot: false)
    }

    private func performBootstrapUninstall(reboot: Bool) {
        guard !isInstallingBootstrap, !isUninstallingBootstrap else { return }
        isUninstallingBootstrap = true
        updateBootstrapAvailability(available: false)
        updateBootstrapUninstallAvailability(available: false)
        Task {
            do {
                let installation = try await control.installedBootstrap()
                guard installation["installed"] as? Bool == true,
                      let roots = installation["roots"] as? [String], !roots.isEmpty
                else {
                    VPhoneAlert.present(
                        title: "Uninstall Bootstrap",
                        message: "No bootstrap environment was found.",
                        style: .informational,
                    )
                    finishBootstrapUninstall()
                    return
                }
                let message = if reboot {
                    VPhoneLocalization.format(
                        "Permanently delete these bootstrap environments and restart the guest?\n%@",
                        roots.joined(separator: "\n"),
                    )
                } else {
                    VPhoneLocalization.format(
                        "Permanently delete these bootstrap environments without restarting the guest?\n%@",
                        roots.joined(separator: "\n"),
                    )
                }
                VPhoneAlert.present(
                    title: "Uninstall Bootstrap",
                    message: message,
                    style: .warning,
                    buttons: [reboot ? "Delete and Restart" : "Delete", "Cancel"],
                ) { response in
                    guard response == .alertFirstButtonReturn else {
                        self.finishBootstrapUninstall()
                        return
                    }
                    Task {
                        do {
                            _ = try await self.control.uninstallBootstrap(at: roots, reboot: reboot)
                            VPhoneAlert.present(
                                title: "Uninstall Bootstrap",
                                message: reboot
                                    ? "Bootstrap removed. The guest is restarting."
                                    : "Bootstrap removed. The guest was not restarted.",
                                style: .informational,
                            )
                        } catch {
                            VPhoneAlert.present(
                                title: "Unable to Remove Bootstrap",
                                message: "Unable to remove the bootstrap. Check that the guest agent is connected, then try again.",
                                style: .warning,
                            )
                        }
                        self.finishBootstrapUninstall()
                    }
                }
            } catch {
                VPhoneAlert.present(
                    title: "Unable to Remove Bootstrap",
                    message: "Unable to remove the bootstrap. Check that the guest agent is connected, then try again.",
                    style: .warning,
                )
                finishBootstrapUninstall()
            }
        }
    }

    private func finishBootstrapUninstall() {
        isUninstallingBootstrap = false
        updateBootstrapAvailability(
            available: control.isConnected && control.guestCapabilities.contains("bootstrap_install"),
        )
        updateBootstrapUninstallAvailability(
            available: control.isConnected && control.guestCapabilities.contains("bootstrap_uninstall"),
        )
    }

    // MARK: - App Registrations

    /// `uicache -a`: registers apps added to or updated in the bootstrap's
    /// /Applications and removes records of apps deleted from it.
    @objc func rebuildAppRegistrations() {
        guard !isInstallingBootstrap, !isUninstallingBootstrap, !isRebuildingAppRegistrations else { return }
        isRebuildingAppRegistrations = true
        rebuildAppRegistrationsItem?.isEnabled = false
        Task {
            defer {
                isRebuildingAppRegistrations = false
                updateBootstrapUninstallAvailability(
                    available: control.isConnected && control.guestCapabilities.contains("bootstrap_uninstall"),
                )
            }
            guard await control.completedBootstrap() != nil else {
                VPhoneAlert.present(
                    title: "Rebuild App Registrations",
                    message: "No bootstrap environment was found.",
                    style: .informational,
                )
                return
            }
            do {
                let result = try await control.rebuildBootstrapAppRegistrations()
                let count = { (key: String) in String((result[key] as? [Any])?.count ?? 0) }
                VPhoneAlert.present(
                    title: "Rebuild App Registrations",
                    message: VPhoneLocalization.format(
                        "Registered %1$@, removed %2$@, %3$@ unchanged.",
                        count("registered"),
                        count("unregistered"),
                        count("unchanged"),
                    ),
                    style: .informational,
                )
            } catch let VPhoneGuestControl.ControlError.guestError(message) where !message.isEmpty {
                VPhoneAlert.present(
                    title: "Unable to Rebuild App Registrations",
                    message: VPhoneLocalization.format("Unable to rebuild app registrations.\n\n%@", message),
                    style: .warning,
                )
            } catch {
                VPhoneAlert.present(
                    title: "Unable to Rebuild App Registrations",
                    message: "Unable to rebuild app registrations. Check that the guest agent is connected, then try again.",
                    style: .warning,
                )
            }
        }
    }

    private func updateBootstrapProgress(
        _ status: [String: Any], label: NSTextField, indicator: NSProgressIndicator,
    ) {
        let procursus = status["source"] as? String == "procursus"
        let package = status["package"] as? String == "sileo" ? "Sileo" : "Procursus"
        switch status["phase"] as? String {
        case "downloading":
            let received = status["downloaded_bytes"] as? Int64 ?? 0
            let total = status["total_bytes"] as? Int64 ?? 0
            if total > 0 {
                indicator.isIndeterminate = false
                indicator.minValue = 0
                indicator.maxValue = Double(total)
                indicator.doubleValue = Double(received)
                let current = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                let expected = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                label.stringValue = procursus
                    ? VPhoneLocalization.format("Downloading %1$@: %2$@ of %3$@", package, current, expected)
                    : VPhoneLocalization.format("Downloading Irisin: %@ of %@", current, expected)
            } else {
                label.stringValue = procursus
                    ? VPhoneLocalization.format("Downloading %@…", package)
                    : VPhoneLocalization.text("Downloading Irisin…")
            }
        case "extracting":
            label.stringValue = VPhoneLocalization.text(procursus ? "Extracting Procursus…" : "Extracting Irisin…")
        case "installing":
            label.stringValue = VPhoneLocalization.text(procursus ? "Installing Procursus and Sileo…" : "Registering Irisin…")
        case "firmware":
            label.stringValue = VPhoneLocalization.text("Recording firmware version…")
        default: break
        }
    }
}
