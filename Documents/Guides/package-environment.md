# Package Environment

The VM has no package manager by default. Choose **Apps > Install Bootstrap…**:

- **Procursus + Sileo** installs the rootless Procursus environment in `/var/jb` and registers Sileo. This uses the [Procursus bootstrap archive](https://apt.procurs.us/bootstraps/1900/) and [Sileo package](https://apt.procurs.us/pool/main/iphoneos-arm64-rootless/3000/sileo/). It is the direct package-manager setup.
- **Irisin (RootHide)** installs Irisin with its RootHide layout. For the full OwnGoal environment:

If you specifically need the deprecated Irisin rootless layout, select **Irisin (rootless, deprecated)** in the same **Install Bootstrap…** chooser. A confirmation offers **Procursus + Sileo** first; choose **Install Irisin Rootless Anyway** to continue. The same confirmation appears when you select rootless for a local Irisin `.deb`.

1. Select **Irisin (RootHide)**. This installs Irisin in the VM.
2. In Irisin, open the **OwnGoal Packages** repository, find **OwnGoal Bootstrap for vphone** (`owngoal-bootstrap-vphone`), and install it with **Bootstrap Install**.

   This one package brings in everything a VM needs in a single pass: `apt` and `dpkg`, `bash`, `zsh` and `dash`, `sudo`, the core command-line tools, `openssh-server`, `curl`, `wget`, `vim`, `git`, `uikittools`, `launchctl`, and the OwnGoal apps. Do not install these packages one by one: several depend on one another, and `openssh-server` declares some dependencies circularly, so separate installs can fail partway.
3. After the first installation, install further packages normally.

**Apps > Install TrollStore Lite…** installs the jailbreak build from [Havoc](https://havoc.app/package/trollstorelite) through iOS 26.0.1, or the [newer registration adaptation](https://github.com/Xplo8E/TrollStore27/releases) on iOS 26.1 and later. It requires a rootless environment with APT and leaves an existing TrollStore installation alone. The installer repairs the Procursus archive's missing `libkrw0-plugin` dependency by removing its unused `shshd`, `libdimentio0`, and `libkrw0` packages when they are still the archive versions and no other installed package needs them. The standard TrollStore app [does not support iOS 17.0.1 or newer](https://github.com/opa334/TrollStore); TrollStore Lite is the appropriate build for a patched guest.

If the first installation fails, do not repair it in place. Choose **Apps > Uninstall Bootstrap…**, then start again from step 1.

## Remove the Environment

Choose **Apps > Uninstall Bootstrap…**. The VM restarts after removal.

Hold Option while opening the **Apps** menu to see two more options:

- **Install Bootstrap from File…:** Installs from a local Irisin `.deb` and asks for its layout.
- **Uninstall Bootstrap Without Restarting…:** Removes the environment without restarting the VM.
