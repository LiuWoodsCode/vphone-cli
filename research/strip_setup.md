# Offline Setup.app removal and setup completion

`make strip_setup` is a recovery action for a restored VM that has completed
`cfw_install` but is stuck in Setup Assistant. Run it while the VM is off.

The host mounts the live APFS System volume read-write and removes
`/Applications/Setup.app`. CFW installation already renamed the boot snapshot so
the guest uses that live volume. The host cannot write PurpleBuddy preferences
directly: the Data volume is encrypted and unavailable during host mounting
(the same constraint noted by the JB CFW installer for `/var/jb`).

The command therefore also adds `com.vphone.setup-complete` to the System
volume's launchd configuration. On guest boot, its small Foundation helper
waits for `/var/mobile/Library/Preferences`, then preserves existing keys and
sets `SetupDone`, `SetupFinishedAllSteps`, and `UserChoseLanguage` in both
`/var/mobile/Library/Preferences/com.apple.purplebuddy.plist` and
`/var/Managed Preferences/mobile/com.apple.purplebuddy.plist`. It synchronizes
the live PurpleBuddy preferences cache for the mobile user. The helper exits
successfully after writing; launchd retries failed early starts at a throttled
interval. Re-running `make strip_setup` is safe when Setup.app is absent.

The two completion flags are used by [Nugget's skip-setup implementation](https://github.com/leminlimez/Nugget/blob/main/src/devicemanagement/device_manager.py).
Its implementation also uses `CloudConfigurationDetails.plist` to skip individual
setup panes through backup restore. That cloud configuration carries device
management state and is intentionally not synthesized here. Apple's
[SkipKeys documentation](https://developer.apple.com/documentation/devicemanagement/skipkeys)
describes the separate managed setup-pane controls. These local preference
flags do not provide an activation ticket or change Apple server activation
state.

Validation: `zsh -n scripts/strip_setup.sh`, `plutil -lint` on the daemon plist,
and an iPhoneOS arm64 clang build plus `ldid -S` signing of the helper. Runtime
validation requires running `make strip_setup` against an offline VM, booting,
and checking the PurpleBuddy plists through the guest file browser or SSH.
