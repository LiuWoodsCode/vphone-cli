#!/bin/zsh
# Remove Setup.app from an offline VM's live System volume. Run after CFW
# installation, which flips the boot snapshot so the guest uses this volume.
set -euo pipefail

SCRIPT_DIR="${0:a:h}"
PROJ="${SCRIPT_DIR:h}"
VM_DIR="${1:-${SCRIPT_DIR:h}/vm}"
VM_DIR="${VM_DIR:a}"
IMG="$VM_DIR/Disk.img"
[[ -f "$IMG" ]] || { echo "[-] no Disk.img at $IMG" >&2; exit 1; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo ${SUDO_ASKPASS:+-A} -E /bin/zsh "$0" "$VM_DIR"
fi
export PATH="$PROJ/.tools/bin:$PROJ/.venv/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if lsof "$IMG" >/dev/null 2>&1; then
  echo "[-] $IMG is in use — stop the VM first." >&2
  exit 1
fi

BASEDISK=""
MNT=""
BUILD_DIR=""
cleanup() {
  local exit_code=$?
  if [[ -n "$MNT" ]]; then
    if mount | /usr/bin/grep -Fq " on $MNT "; then
      /sbin/umount "$MNT" || { echo "[-] could not unmount $MNT" >&2; exit_code=1; }
    fi
    /bin/rmdir "$MNT" 2>/dev/null || true
  fi
  if [[ -n "$BASEDISK" ]]; then
    hdiutil detach "$BASEDISK" || diskutil eject "$BASEDISK" || { echo "[-] could not detach $BASEDISK" >&2; exit_code=1; }
  fi
  if [[ -n "$BUILD_DIR" ]]; then
    /bin/rm -f "$BUILD_DIR/vphone_setup_complete" "$BUILD_DIR/launchd.plist"
    /bin/rmdir "$BUILD_DIR" 2>/dev/null || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT

echo "[*] attaching $IMG read-write"
AO=$(hdiutil attach -readwrite -nomount -imagekey diskimage-class=CRawDiskImage "$IMG")
BASEDISK=$(awk 'NR == 1 { print $1; exit }' <<< "$AO")
[[ "$BASEDISK" == /dev/disk<-> ]] || { echo "[-] could not identify attached disk" >&2; exit 1; }

CONT=$(diskutil info -plist "${BASEDISK}s1" | /usr/bin/plutil -extract APFSContainerReference raw -o - -)
[[ "$CONT" == disk<-> ]] || { echo "[-] APFS container not found in $IMG" >&2; exit 1; }
SYS=$(diskutil apfs list "$CONT" | awk '/APFS Volume Disk \(Role\):/{for(i=1;i<=NF;i++) if($i ~ /^disk[0-9]+s[0-9]+$/) dev=$i} /Name:.*System \(Case-sensitive\)/{print dev; exit}')
[[ -n "$SYS" ]] || { echo "[-] System volume not found in $IMG" >&2; exit 1; }

MNT=$(mktemp -d /private/tmp/vphone-strip-setup.XXXXXX)
/sbin/mount_apfs -o rw "/dev/$SYS" "$MNT"
MOUNT_LINE=$(mount | /usr/bin/grep -F "/dev/$SYS on $MNT " || true)
[[ -n "$MOUNT_LINE" ]] || { echo "[-] System volume did not mount at $MNT" >&2; exit 1; }
[[ "$MOUNT_LINE" != *read-only* ]] || { echo "[-] System volume mounted read-only" >&2; exit 1; }

SETUP="$MNT/Applications/Setup.app"
if [[ -L "$MNT/Applications" || -L "$SETUP" ]]; then
  echo "[-] refusing to follow a symlink to Setup.app" >&2
  exit 1
fi

# The Data volume is encrypted and unavailable to the host. Stage a launchd
# helper that writes PurpleBuddy completion flags after Data mounts in iOS.
command -v ldid >/dev/null || { echo "[-] ldid is required (run make setup_tools)" >&2; exit 1; }
BUILD_DIR=$(mktemp -d /private/tmp/vphone-setup-build.XXXXXX)
xcrun -sdk iphoneos clang -arch arm64 -Os -fobjc-arc \
  -o "$BUILD_DIR/vphone_setup_complete" "$SCRIPT_DIR/vphone_setup_complete.m" \
  -framework Foundation
ldid -S "$BUILD_DIR/vphone_setup_complete"
/bin/mkdir -p "$MNT/cores" "$MNT/System/Library/LaunchDaemons"
/bin/cp "$BUILD_DIR/vphone_setup_complete" "$MNT/cores/vphone_setup_complete"
/bin/chmod 0755 "$MNT/cores/vphone_setup_complete"
/usr/sbin/chown 0:0 "$MNT/cores/vphone_setup_complete"
/bin/cp "$SCRIPT_DIR/vphone_setup_complete.plist" "$MNT/System/Library/LaunchDaemons/com.vphone.setup-complete.plist"
/bin/chmod 0644 "$MNT/System/Library/LaunchDaemons/com.vphone.setup-complete.plist"
/usr/sbin/chown 0:0 "$MNT/System/Library/LaunchDaemons/com.vphone.setup-complete.plist"

LAUNCHD="$MNT/System/Library/xpc/launchd.plist"
[[ -f "$LAUNCHD" && ! -L "$LAUNCHD" ]] || { echo "[-] launchd.plist not found on System volume" >&2; exit 1; }
[[ -f "$LAUNCHD.vphone-strip-setup.bak" ]] || /bin/cp "$LAUNCHD" "$LAUNCHD.vphone-strip-setup.bak"
"${PROJ}/.venv/bin/python3" - "$LAUNCHD" "$SCRIPT_DIR/vphone_setup_complete.plist" "$BUILD_DIR/launchd.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    launchd = plistlib.load(source)
with open(sys.argv[2], "rb") as source:
    daemon = plistlib.load(source)
launchd.setdefault("LaunchDaemons", {})[
    "/System/Library/LaunchDaemons/com.vphone.setup-complete.plist"
] = daemon
with open(sys.argv[3], "wb") as output:
    plistlib.dump(launchd, output, sort_keys=False)
PY
/bin/cp "$BUILD_DIR/launchd.plist" "$LAUNCHD"
/bin/chmod 0644 "$LAUNCHD"
/usr/sbin/chown 0:0 "$LAUNCHD"
echo "[*] staged first-boot PurpleBuddy completion helper"

if [[ ! -d "$SETUP" ]]; then
  echo "[*] /Applications/Setup.app is already absent"
else
  echo "[*] removing /Applications/Setup.app from $SYS"
  /bin/rm -rf "$SETUP"
  [[ ! -e "$SETUP" ]] || { echo "[-] Setup.app is still present" >&2; exit 1; }
fi
echo "[+] Setup.app absent; setup completion will be recorded on the next boot. Boot with: make boot"
