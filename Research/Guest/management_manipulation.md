# Management manipulation

Device → Manipulate Management offers restore, removal, a Jamf-only URL
replacement, and passcode policy removal. These operations run through vphoned as root and schedule a full
guest reboot after a successful apply. They do not run an iOS device restore.

## Paths

The backup domain `SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles`
maps to `/var/containers/Shared/SystemGroup/<container>/Library/ConfigurationProfiles`.
vphoned finds the container by the `MCMMetadataIdentifier` in its metadata plist;
it does not assume a fixed UUID. This matches [Nugget's domain mapping and
`CloudConfigurationDetails.plist` placement](https://raw.githubusercontent.com/leminlimez/Nugget/refs/heads/main/src/devicemanagement/device_manager.py).

Restore accepts the decrypted backup's `Library/ConfigurationProfiles` folder.
The host inventories every file and subdirectory, including empty directories,
uploads every file with its original mode, and sends file SHA-256 hashes and
directory paths to the guest. The guest verifies every listed upload, builds a
replacement directory from those files and directories, then verifies every
copy. It moves the existing profile directory aside and swaps in the new one,
so all old files are removed even when the backup has a different set of files.
A failed swap restores the old directory. The guest removes staging after success.
If the folder contains `CloudConfigurationDetails.plist`, the host then uses
the bundled CLI's native libimobiledevice bridge to send
`SetCloudConfiguration` to the guest's `com.apple.mobile.MCInstall` service,
checks every restored `CloudConfigurationDetails.plist` field against
`GetCloudConfiguration` (allowing iOS to normalize `ConfigurationSource` from
0 to 2), and only then
asks vphoned to reboot.

## Why the service call matters

On the iPadOS 26.5 test guest, replacing the folder with a plist containing
`IsSupervised = true` and `OrganizationName = Kamabo Co` and rebooting left
Settings and Apple Configurator showing no supervision. iOS moved that file
under a `9C3EFE3` subdirectory, and the plist still read back with those keys,
but `pymobiledevice3 profile cloud-configuration` returned `null` from
`MCInstall`. Adding `OrganizationMagic` and `SupervisorHostCertificates` to the
file and rebooting still left the service state absent. Sending the same
configuration through `SetCloudConfiguration` was acknowledged; a subsequent
`GetCloudConfiguration` returned `IsSupervised = true`,
`OrganizationName = Kamabo Co`, and `ConfigurationSource = 2`, and Settings
then showed supervision. The extra certificate is an identity field, not an
MDM enrollment profile. The earlier file-only claim was false for this build.

Removal clears the system group configuration profile folder,
`/var/mobile/Library/UserConfigurationProfiles`, and
`/var/Managed Preferences`. These cover device and user profiles and managed
preferences for every user. It leaves other preference domains alone.

The Jamf fix scans `.plist` and profile `.stub` files recursively in those
three stores. It replaces `jamfcloud.com` with `ddlc.moe/jamf` in equal-length
UTF-8/ASCII, UTF-16BE, and UTF-16LE byte sequences. The equal byte counts
keep binary plist object offsets stable. It writes changed files atomically
and restores their ownership and mode.

Passcode removal scans parseable XML and binary property lists recursively in
all three management stores. It drops passcode payloads
(`com.apple.mobiledevice.passwordpolicy` and declarative
`com.apple.configuration.passcode.settings`) and passcode policy keys from
derived restriction and effective-settings caches, Shared iPad user passcode
types, and Exchange policy values. It retains unrelated settings, writes in
each file's original property-list format, and restores
ownership and mode. An MDM or Exchange server can reapply a passcode policy
after reconnecting.

## Validation

- Build the `VPhone` scheme to compile the host and guest changes and validate
  the bundle.
- On a disposable guest with a matching decrypted backup, restore the profile
  folder, confirm MCInstall accepts its cloud configuration, then verify MDM,
  supervision, and profiles in Settings after reboot.
- On a separate disposable guest, exercise removal and Jamf replacement and
  check the three stores and reboot. The Jamf action is specific to Jamf Cloud;
  other providers have no matching URL.
