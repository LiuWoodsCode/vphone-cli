# Package Environment

The VM has no package manager by default. Choose **Apps > Install Bootstrap…**:

- **Procursus + Sileo** installs the rootless Procursus environment in `/var/jb` and registers Sileo. This uses the [Procursus bootstrap archive](https://apt.procurs.us/bootstraps/1900/) and [Sileo package](https://apt.procurs.us/pool/main/iphoneos-arm64-rootless/3000/sileo/). It is the direct package-manager setup.
- **Irisin** keeps the existing RootHide or rootless route. For the full OwnGoal environment:

1. Select the **roothide** layout. This installs Irisin in the VM.
2. In Irisin, open the **OwnGoal Packages** repository, find **OwnGoal Bootstrap for vphone** (`owngoal-bootstrap-vphone`), and install it with **Bootstrap Install**.

   This one package brings in everything a VM needs in a single pass: `apt` and `dpkg`, `bash`, `zsh` and `dash`, `sudo`, the core command-line tools, `openssh-server`, `curl`, `wget`, `vim`, `git`, `uikittools`, `launchctl`, and the OwnGoal apps. Do not install these packages one by one: several depend on one another, and `openssh-server` declares some dependencies circularly, so separate installs can fail partway.
3. After the first installation, install further packages normally.

**Apps > Install TrollStore Lite…** installs the jailbreak build from [Havoc](https://havoc.app/package/trollstorelite), or the [iOS 27 adaptation](https://github.com/Xplo8E/TrollStore27/releases) on iOS 27. It requires a rootless environment with APT and leaves an existing TrollStore installation alone. The standard TrollStore app [does not support iOS 17.0.1 or newer](https://github.com/opa334/TrollStore); TrollStore Lite is the appropriate build for a patched guest.

If the first installation fails, do not repair it in place. Choose **Apps > Uninstall Bootstrap…**, then start again from step 1.

## Remove the Environment

Choose **Apps > Uninstall Bootstrap…**. The VM restarts after removal.

Hold Option while opening the **Apps** menu to see two more options:

- **Install Bootstrap from File…:** Installs from a local Irisin `.deb`.
- **Uninstall Bootstrap Without Restarting…:** Removes the environment without restarting the VM.
