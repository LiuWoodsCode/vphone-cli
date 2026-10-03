# Restore configuration profile backup state

`make sup_bak SOURCE=<directory>` stages the contents of a decrypted backup's
`ConfigurationProfiles` directory on the VM's live System volume. For example:

```sh
make sup_bak SOURCE=/Users/dapixelprowler/iDeviceBackups/decrypted/00008122-001C615A2633801C.unback/SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles
```

Run with the VM off, after `cfw_install` has selected the live System volume.
The host cannot mount the encrypted Data volume. It therefore installs
`com.vphone.sup-bak` and a small Objective-C helper on System; launchd starts the
helper during boot, and it waits for the shared SystemGroup path on Data before
copying the staged directory contents into
`/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles`.
Existing files with the same names are replaced. The copy includes nested
directories such as `PublicInfo` and rejects symlinks in the input.

`make sup_bak REMOVE=1` queues removal on the next boot of files and nested
contents named by the staged payload. It leaves unrelated files in the target
directory in place. `make sup_bak DISABLE=1` removes the LaunchDaemons entry,
daemon plist, helper, and mode marker from System; staged payload data remains
available if the service is installed again.

The backup may contain device management configuration, profile stubs, home
screen layout, and related settings. The command copies those backup files as-is;
it does not merge or rewrite plist contents. Runtime verification requires
booting the VM and inspecting the target files.

## Nugget path comparison

Nugget's current [`add_skip_setup`](https://github.com/leminlimez/Nugget/blob/main/src/devicemanagement/device_manager.py)
implementation places `CloudConfigurationDetails.plist` at
`Library/ConfigurationProfiles/CloudConfigurationDetails.plist` in
`SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles`. That
maps to the shared SystemGroup target used by this helper, so the supplied
`ConfigurationProfiles` directory already goes to the right place. Nugget also
adds PurpleBuddy completion flags separately at
`mobile/com.apple.purplebuddy.plist` in `ManagedPreferencesDomain`, which maps
to `/var/Managed Preferences/mobile/com.apple.purplebuddy.plist`. The existing
`strip_setup` helper already writes that managed preference file, so those
flags do not belong in the configuration-profiles directory. Nugget builds
`SkipSetup` and other cloud configuration flags in the cloud plist; `sup_bak`
intentionally restores the backup plist verbatim instead of rewriting its
management state.
