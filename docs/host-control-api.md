# VPhone Host Control API

VPhoneHostControl exposes a Unix-domain socket for local programs controlling a
running VM. The usual path is vm/vphone.sock; the actual path is the VM
configuration path passed to the application.

This is a privileged local-control interface. A process able to open the socket
can inject input, read or modify guest files, inspect keychain data, change
preferences, and launch applications.

## Transport and responses

- Transport is Unix AF_UNIX/SOCK_STREAM.
- Requests and responses are UTF-8 JSON, one object per newline.
- One connection may carry multiple requests.
- id is optional and is echoed unchanged.
- Numeric strings are accepted for coordinates, durations, and battery values.
- Requests are limited to 16 MiB.

Example:

    SOCK=vm/vphone.sock
    printf '%s\n' '{"t":"ping","id":"1"}' | nc -U "$SOCK"

Typical success and error responses:

    {"ok":true,"id":"1"}
    {"ok":false,"error":"guest not connected","id":"1"}
    {"v":1,"t":"err","msg":"missing path","id":"1"}

Guest responses retain their v and t fields. Raw guest binary responses are
converted by the host to base64 in data, with encoding set to base64 and size
set to the decoded byte count. This applies to file_get and image
clipboard_get.

## Screenshots

Add screen:true to any normal request to append image, a compact grayscale
JPEG encoded as base64, after the operation completes. delay is an optional
post-operation delay in milliseconds, default 500. It is clamped to zero or
greater; swipe also adds its gesture duration.

    {"t":"tap","x":645,"y":1398,"screen":true,"delay":750}

The screenshot operation captures the current display. Its optional path is a
host path for a full-resolution screenshot; image is also returned.

    {"t":"screenshot","path":"/tmp/vphone-home.png","id":"shot-1"}

It fails with no active VM view when the VM window is unavailable.

## Input

### tap

Injects a tap using screenshot pixel coordinates. (0,0) is top-left.

    {"t":"tap","x":645,"y":1398}

Requires numeric x and y.

### swipe

Injects a swipe using screenshot pixel coordinates. ms is duration in
milliseconds and defaults to 300.

    {"t":"swipe","x1":645,"y1":2100,"x2":645,"y2":700,"ms":600}

Requires x1, y1, x2, and y2.

### key, key_down, key_up

Supported names are case-insensitive:

| Name | HID page | HID usage | Meaning |
| --- | ---: | ---: | --- |
| home | 0x0c | 0x40 | Home |
| power | 0x0c | 0x30 | Power/lock |
| volup, volume_up | 0x0c | 0xe9 | Volume up |
| voldown, volume_down | 0x0c | 0xea | Volume down |

key sends a press unless boolean down is supplied. The aliases force state:

    {"t":"key","name":"home"}
    {"t":"key_down","name":"power"}
    {"t":"key_up","name":"power"}

Use hid for arbitrary usages. Omit down for a press; otherwise use true or
false for down/up.

    {"t":"hid","page":12,"usage":64,"down":true}

### touch

Forwards a guest-side digitizer event. Coordinates are normalized, top-left
origin. phase is 0 (down), 1 (move), or 3 (up).

    {"t":"touch","phase":0,"x":0.50,"y":0.75}
    {"t":"touch","phase":3,"x":0.50,"y":0.75}

## Battery

Battery commands are host-side and do not require vphoned. Charge is 0-100.
Connectivity is 1, or charging/connected/ac, for powered; and 2, or
disconnected/not_charging/battery, for disconnected.

    {"t":"battery_status"}

The response contains guest_charge, guest_connectivity, sync_enabled, and
low_power_mode. host_charge and host_connectivity appear when macOS reports an
internal battery.

    {"t":"battery_set","charge":50,"connectivity":"disconnected"}
    {"t":"battery_level","level":15}
    {"t":"battery_connectivity","state":"charging"}

battery_set changes both values; battery_level changes only charge; and
battery_connectivity changes only connectivity. Success returns charge and
connectivity. Invalid values are rejected.

The same actions can be selected through the generic battery operation:

    {"t":"battery","action":"status"}
    {"t":"battery","action":"set","charge":50,"connectivity":2}
    {"t":"battery","action":"sync","enabled":true}

    {"t":"battery_sync","enabled":true}
    {"t":"battery_sync","enabled":false}

enabled defaults to true. Enabling immediately copies the host battery when
available.

## Guest files

These require the guest file capability. All paths are guest paths.

| Operation | Request fields | Result |
| --- | --- | --- |
| file_list | path | entries |
| file_get | path | base64 data, encoding, size |
| file_put | path, base64 data, optional octal perm | path, size |
| file_mkdir | path | ok |
| file_delete | path | ok |
| file_rename | from, to | ok |

file_list entries contain name, type (file, dir, link), link_target_dir, size,
octal-string perm, and Unix-seconds mtime. file_put defaults perm to 644,
creates missing parents, and installs through a temporary file atomically.

    printf '%s\n' '{"t":"file_list","path":"/var/mobile/Documents"}' | nc -U vm/vphone.sock
    printf '%s\n' '{"t":"file_get","path":"/var/mobile/Documents/example.txt"}' | nc -U vm/vphone.sock

For upload:

    DATA=$(base64 < ./example.txt | tr -d '\n')
    printf '{"t":"file_put","path":"/var/mobile/Documents/example.txt","data":"%s","perm":"644"}\n' "$DATA" | nc -U vm/vphone.sock

The host rejects invalid base64 before contacting the guest.

## Clipboard

clipboard_get returns optional text, types, has_image, and change_count. Image
bytes are returned as base64 data. Text and image writes are:

    {"t":"clipboard_set","text":"hello from vphone"}
    {"t":"clipboard_set","image_base64":"<base64 image bytes>"}

Image payloads are limited to 50 MiB by the guest. Successful writes return ok
and the new change_count.

## Keychain

keychain_list optionally accepts class: genp, inet, cert, or keys.

    {"t":"keychain_list"}
    {"t":"keychain_list","class":"genp"}

The response contains items, count, and diag. Items may contain class, account,
service, accessGroup, label, value, valueEncoding (utf8 or base64), valueSize,
createdStr, modifiedStr, protection, _rowid, and Internet-password fields
server, protocol, port, and path.

keychain_add adds or replaces a generic-password test item:

    {"t":"keychain_add","account":"alice","service":"example","password":"secret"}

All fields are optional; defaults are vphone-test, vphone, and testpass123.
The response includes ok and the Security framework status code (0 is success).

## Applications and URLs

app_list accepts filter: all (default), user, system, or running.

    {"t":"app_list","filter":"user"}

Each item has bundle_id, name, version, type, state (running or not_running),
pid (zero when not running), path, and data_container.

    {"t":"app_launch","bundle_id":"com.apple.Preferences"}
    {"t":"app_launch","bundle_id":"com.apple.mobilesafari","url":"https://example.com"}
    {"t":"app_terminate","bundle_id":"com.apple.Preferences"}
    {"t":"app_foreground"}
    {"t":"open_url","url":"prefs:root=General"}

app_launch returns ok and pid. app_foreground returns bundle_id, name, and pid.
open_url returns ok and includes msg on failure.

## Settings

settings_get reads a CFPreferences domain. Omit key to read all keys:

    {"t":"settings_get","domain":"com.apple.springboard","key":"SBShowBatteryPercentage"}
    {"t":"settings_get","domain":"com.apple.springboard"}

A single value includes value and type: null, boolean, integer, float, string,
data, or plist. Data is base64. A whole-domain response has type dictionary
and wraps each entry with its own value and type.

    {"t":"settings_set","domain":"com.apple.springboard","key":"SBShowBatteryPercentage","value":true,"type":"boolean"}
    {"t":"settings_set","domain":"com.example.test","key":"count","value":3,"type":"integer"}

Type hints are boolean, integer, float, string, and data; data requires
base64. Omitting type passes the JSON value through.

## Location and system state

Location units are degrees, meters, meters/second, and degrees for course:

    {"t":"location","lat":40.7128,"lon":-74.0060,"alt":10,"hacc":5,"vacc":10,"speed":0,"course":-1}
    {"t":"location_stop"}

devmode supports status and enable. A newly armed state requires reboot:

    {"t":"devmode","action":"status"}
    {"t":"devmode","action":"enable"}

Other system operations:

    {"t":"low_power_mode","enabled":true}
    {"t":"ping"}
    {"t":"version"}

low_power_mode returns ok; ping returns t=pong; version returns the vphoned
build hash in hash.

## IPA installation

If host_path (or path) names an existing host file, the host stages the IPA
under /var/mobile/Documents/vphone-installs, uploads it, optionally uploads the
signing certificate, and invokes the guest installer:

    {"t":"ipa_install","host_path":"/Users/me/Build/MyApp.ipa"}

If the path is not an existing host file, the request is forwarded unchanged:

    {"t":"ipa_install","path":"/var/mobile/Documents/MyApp.ipa","registration":"User"}

The host form returns ok and msg and removes temporary staged files. The guest
must support ipa_install.

## Accessibility and forwarding

accessibility_tree accepts optional integer depth (default -1):

    {"t":"accessibility_tree","depth":3}

The current handler is a stub and returns an error stating that it is not
implemented.

The guest handshake reports capabilities such as hid, devmode, file, keychain,
location, ipa_install, clipboard, apps, url, settings, and touch. Availability
depends on the guest OS and loaded private frameworks.

Any operation not consumed specially by VPhoneHostControl is forwarded with
its normal t and fields to vphoned. This supports future guest operations; the
operations defined by the current implementation are listed above.

## Complete shell example

    SOCK=vm/vphone.sock
    printf '%s\n' '{"t":"ping","id":"ping-1"}' | nc -U "$SOCK"
    printf '%s\n' '{"t":"app_launch","bundle_id":"com.apple.Preferences","id":"launch-1"}' | nc -U "$SOCK"
    printf '%s\n' '{"t":"screenshot","path":"/tmp/settings.png","id":"shot-1"}' | nc -U "$SOCK"
