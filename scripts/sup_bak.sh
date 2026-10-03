#!/bin/zsh
# Stage ConfigurationProfiles backup contents and install a guest-side copier.
set -euo pipefail

SCRIPT_DIR="${0:a:h}"
PROJ="${SCRIPT_DIR:h}"
VM_DIR="${1:-${PROJ}/vm}"
SOURCE="${2:-}"
DISABLE="${3:-0}"
REMOVE="${4:-0}"
VM_DIR="${VM_DIR:a}"
IMG="$VM_DIR/Disk.img"
LABEL="com.vphone.sup-bak"
HELPER="vphone_sup_bak"
STAGE="vphone_sup_bak_data"
MODE="vphone_sup_bak_mode"
DAEMON_FILE="vphone_sup_bak.plist"
[[ -f "$IMG" ]] || { echo "[-] no Disk.img at $IMG" >&2; exit 1; }
[[ "$DISABLE" == 0 || "$DISABLE" == 1 ]] || { echo "[-] DISABLE must be 0 or 1" >&2; exit 1; }
[[ "$REMOVE" == 0 || "$REMOVE" == 1 ]] || { echo "[-] REMOVE must be 0 or 1" >&2; exit 1; }
if [[ "$DISABLE" == 1 && "$REMOVE" == 1 ]]; then
  echo "[-] DISABLE=1 and REMOVE=1 are separate operations" >&2; exit 1
fi
if [[ "$DISABLE" != 1 && "$REMOVE" != 1 ]]; then
  [[ -n "$SOURCE" && -d "$SOURCE" ]] || { echo "[-] provide SOURCE=<ConfigurationProfiles directory>" >&2; exit 1; }
  SOURCE="${SOURCE:a}"
  [[ "${SOURCE:t}" == ConfigurationProfiles ]] || { echo "[-] SOURCE must be the ConfigurationProfiles directory" >&2; exit 1; }
fi
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo ${SUDO_ASKPASS:+-A} -E /bin/zsh "$0" "$VM_DIR" "$SOURCE" "$DISABLE" "$REMOVE"
fi
export PATH="$PROJ/.tools/bin:$PROJ/.venv/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if lsof "$IMG" >/dev/null 2>&1; then echo "[-] $IMG is in use — stop the VM first." >&2; exit 1; fi

BASEDISK=""; MNT=""; BUILD_DIR=""
cleanup() {
  local code=$?
  if [[ -n "$MNT" ]]; then
    if mount | /usr/bin/grep -Fq " on $MNT "; then /sbin/umount "$MNT" || code=1; fi
    /bin/rmdir "$MNT" 2>/dev/null || true
  fi
  if [[ -n "$BASEDISK" ]]; then hdiutil detach "$BASEDISK" || diskutil eject "$BASEDISK" || code=1; fi
  [[ -z "$BUILD_DIR" ]] || { /bin/rm -rf "$BUILD_DIR"; }
  exit "$code"
}
trap cleanup EXIT

AO=$(hdiutil attach -readwrite -nomount -imagekey diskimage-class=CRawDiskImage "$IMG")
BASEDISK=$(awk 'NR == 1 { print $1; exit }' <<< "$AO")
[[ "$BASEDISK" == /dev/disk<-> ]] || { echo "[-] could not identify attached disk" >&2; exit 1; }
CONT=$(diskutil info -plist "${BASEDISK}s1" | /usr/bin/plutil -extract APFSContainerReference raw -o - -)
SYS=$(diskutil apfs list "$CONT" | awk '/APFS Volume Disk \(Role\):/{for(i=1;i<=NF;i++) if($i ~ /^disk[0-9]+s[0-9]+$/) dev=$i} /Name:.*System \(Case-sensitive\)/{print dev; exit}')
[[ -n "$SYS" ]] || { echo "[-] System volume not found in $IMG" >&2; exit 1; }
MNT=$(mktemp -d /private/tmp/vphone-sup-bak.XXXXXX)
/sbin/mount_apfs -o rw "/dev/$SYS" "$MNT"
MOUNT_LINE=$(mount | /usr/bin/grep -F "/dev/$SYS on $MNT " || true)
[[ -n "$MOUNT_LINE" && "$MOUNT_LINE" != *read-only* ]] || { echo "[-] System volume not mounted read-write" >&2; exit 1; }
LAUNCHD="$MNT/System/Library/xpc/launchd.plist"
DAEMON_PATH="$MNT/System/Library/LaunchDaemons/$LABEL.plist"
if [[ "$DISABLE" == 1 ]]; then
  [[ -f "$LAUNCHD" && ! -L "$LAUNCHD" ]] || { echo "[-] launchd.plist not found" >&2; exit 1; }
  BUILD_DIR=$(mktemp -d /private/tmp/vphone-sup-bak-build.XXXXXX)
  "${PROJ}/.venv/bin/python3" - "$LAUNCHD" "$BUILD_DIR/launchd.plist" "$DAEMON_PATH" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f: data = plistlib.load(f)
data.get("LaunchDaemons", {}).pop(sys.argv[3], None)
with open(sys.argv[2], "wb") as f: plistlib.dump(data, f, sort_keys=False)
PY
  /bin/cp "$BUILD_DIR/launchd.plist" "$LAUNCHD"
  /bin/rm -f "$DAEMON_PATH" "$MNT/cores/$HELPER" "$MNT/cores/$MODE"
  echo "[+] sup_bak launchd service disabled"
  exit 0
fi

command -v ldid >/dev/null || { echo "[-] ldid is required (run make setup_tools)" >&2; exit 1; }
BUILD_DIR=$(mktemp -d /private/tmp/vphone-sup-bak-build.XXXXXX)
xcrun -sdk iphoneos clang -arch arm64 -Os -fobjc-arc -o "$BUILD_DIR/$HELPER" "$SCRIPT_DIR/vphone_sup_bak.m" -framework Foundation
ldid -S "$BUILD_DIR/$HELPER"
/bin/mkdir -p "$MNT/cores" "$MNT/System/Library/LaunchDaemons"
if [[ "$REMOVE" == 1 ]]; then
  [[ -d "$MNT/cores/$STAGE" ]] || { echo "[-] no prior sup_bak payload is staged" >&2; exit 1; }
  /usr/bin/touch "$MNT/cores/$MODE"
  /bin/echo -n remove > "$MNT/cores/$MODE"
else
  /bin/rm -rf "$MNT/cores/$STAGE"
  /bin/mkdir -p "$MNT/cores/$STAGE"
  # Only regular files/directories are accepted; do not import backup symlinks.
  /usr/bin/ditto --noqtn "$SOURCE" "$MNT/cores/$STAGE"
  if find "$MNT/cores/$STAGE" -type l -print -quit | /usr/bin/grep -q .; then
    echo "[-] backup contains symlinks; refusing to stage it" >&2; exit 1
  fi
  /bin/echo -n install > "$MNT/cores/$MODE"
fi
/bin/cp "$BUILD_DIR/$HELPER" "$MNT/cores/$HELPER"
/bin/chmod 0755 "$MNT/cores/$HELPER" "$MNT/cores/$MODE"
/usr/sbin/chown 0:0 "$MNT/cores/$HELPER" "$MNT/cores/$MODE"
/bin/cp "$SCRIPT_DIR/$DAEMON_FILE" "$DAEMON_PATH"
/bin/chmod 0644 "$DAEMON_PATH"; /usr/sbin/chown 0:0 "$DAEMON_PATH"
[[ -f "$LAUNCHD" && ! -L "$LAUNCHD" ]] || { echo "[-] launchd.plist not found" >&2; exit 1; }
"${PROJ}/.venv/bin/python3" - "$LAUNCHD" "$DAEMON_PATH" "$BUILD_DIR/launchd.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f: launchd = plistlib.load(f)
with open(sys.argv[2], "rb") as f: daemon = plistlib.load(f)
launchd.setdefault("LaunchDaemons", {})["/System/Library/LaunchDaemons/" + sys.argv[2].rsplit("/", 1)[-1]] = daemon
with open(sys.argv[3], "wb") as f: plistlib.dump(launchd, f, sort_keys=False)
PY
/bin/cp "$BUILD_DIR/launchd.plist" "$LAUNCHD"
/bin/chmod 0644 "$LAUNCHD"; /usr/sbin/chown 0:0 "$LAUNCHD"
if [[ "$REMOVE" == 1 ]]; then echo "[+] queued removal of managed files installed by sup_bak";
else echo "[+] staged backup; files will be restored into ConfigurationProfiles on boot"; fi
