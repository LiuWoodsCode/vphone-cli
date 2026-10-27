import AppKit

// MARK: - Management Menu

extension VPhoneMenuController {
    func addManagementItem(to menu: NSMenu) {
        let item = makeItem("Manipulate Management…", action: #selector(manipulateManagement), symbol: "person.crop.rectangle.stack")
        item.isEnabled = false
        manipulateManagementItem = item
        menu.addItem(item)
    }

    func updateManagementAvailability(available: Bool) {
        manipulateManagementItem?.isEnabled = available && !isManipulatingManagement
    }

    @objc func manipulateManagement() {
        VPhoneAlert.present(
            title: "Manipulate Management",
            message: "Choose a change for this guest. Each applied change restarts the guest automatically.",
            style: .warning,
            buttons: ["Restore From Backup", "Remove Management", "Fix Jamf Unenrollment", "Remove Passcode Requirements", "Cancel"],
        ) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: self.chooseManagementBackup()
            case .alertSecondButtonReturn: self.confirmManagementRemoval()
            case .alertThirdButtonReturn: self.confirmJamfFix()
            case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3):
                self.confirmPasscodeRemoval()
            default: break
            }
        }
    }

    private func chooseManagementBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = VPhoneLocalization.text("Restore")
        panel.message = VPhoneLocalization.text("Select Library/ConfigurationProfiles from the decrypted SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles backup.")
        VPhoneAlert.present(panel) { [weak self] response in
            guard response == .OK, let self, let directory = panel.url else { return }
            guard directory.lastPathComponent == "ConfigurationProfiles",
                  directory.deletingLastPathComponent().lastPathComponent == "Library",
                  directory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles" else {
                VPhoneAlert.present(
                    title: "Wrong Backup Folder",
                    message: "Select SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles from a decrypted backup.",
                    style: .warning,
                )
                return
            }
            VPhoneAlert.present(
                title: "Restore Management?",
                message: "This replaces the guest's configuration profiles, supervision, and MDM files with the selected backup folder, then restarts the guest.",
                style: .warning,
                buttons: ["Restore and Restart", "Cancel"],
            ) { [weak self] answer in
                guard answer == .alertFirstButtonReturn else { return }
                guard let self, let configURL = self.vm?.configURL else { return }
                self.performManagementChange {
                    try await $0.restoreManagement(from: directory, vmDirectory: configURL.deletingLastPathComponent())
                }
            }
        }
    }

    private func confirmManagementRemoval() {
        VPhoneAlert.present(
            title: "Remove Management?",
            message: "This deletes the guest's device and user configuration profiles and managed preferences, including supervision and MDM settings, then restarts the guest.",
            style: .warning,
            buttons: ["Remove and Restart", "Cancel"],
        ) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performManagementChange { try await $0.removeManagement() }
        }
    }

    private func confirmJamfFix() {
        VPhoneAlert.present(
            title: "Fix Jamf Unenrollment?",
            message: "This changes your MDM settings by replacing Jamf Cloud URLs in profile plists, including binary plists, then restarts the guest. It works only for Jamf and does not work for other MDM providers.",
            style: .warning,
            buttons: ["Fix Jamf and Restart", "Cancel"],
        ) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performManagementChange { try await $0.fixJamfUnenrollment() }
        }
    }

    private func confirmPasscodeRemoval() {
        VPhoneAlert.present(
            title: "Remove Passcode Requirements?",
            message: "This removes passcode policy payloads and cached passcode restrictions from management plists, including binary plists, then restarts the guest. MDM or Exchange may send the policy again later.",
            style: .warning,
            buttons: ["Remove and Restart", "Cancel"],
        ) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performManagementChange { try await $0.removePasscodeRequirements() }
        }
    }

    private func performManagementChange(_ operation: @escaping (VPhoneGuestControl) async throws -> Int) {
        guard !isManipulatingManagement else { return }
        isManipulatingManagement = true
        manipulateManagementItem?.isEnabled = false
        Task {
            do {
                let count = try await operation(control)
                print("[management] changed \(count) entries; guest reboot scheduled")
            } catch {
                print("[management] change failed: \(error)")
                VPhoneAlert.present(title: "Unable to Manipulate Management", message: String(describing: error), style: .warning)
            }
            isManipulatingManagement = false
            updateManagementAvailability(available: control.guestCapabilities.contains("management_manipulation"))
        }
    }
}
