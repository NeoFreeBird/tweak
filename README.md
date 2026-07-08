<div align="center">
    <img src="icon_rounded.png" alt="NeoFreeBird-BHTwitter" width="130" height="130">

  # NeoFreeBird-BHTwitter (tweak)
  <i>The ultimate way to tweak your Twitter/X experience.</i>
</div>
<br>

> [!WARNING]
> <b>Please do not create issues regarding sign in or Tweeting.</b><br>Twitter/X have added Attestation to prevent the use of third-paty or modified clients. We cannot do anything against this. Please do not create new issues regarding this.

| | | |
|:-------------------------:|:-------------------------:|:-------------------------:|
|<img width="1604" alt="Screenshot 1" src="1.png">|<img width="1604" alt="Screenshot 2" src="2.png">|<img width="1604" alt="Screenshot 3" src="3.png">|

# Compiling NeoFreeBird-BHTwitter

## Using your computer

1. Install [Theos](https://github.com/theos/theos).

> Note for Linux users: the current toolchain that ships with Theos is too outdated to build successfully ("Undefined symbols for architecture arm64"). Download the latest toolchain for your distro from [here](https://github.com/L1ghtmann/swift-toolchain-linux/releases/latest) and replace `$THEOS/toolchain/linux` with its contents.

2. Install [cyan](https://github.com/asdfzxcvbn/pyzule-rw) if you want sideload or TrollStore builds.
3. Clone the NeoFreeBird-BHTwitter repository:

```bash
git clone --recursive https://github.com/NeoFreeBird/tweak
cd tweak
```

4. Make the build script executable:

```bash
chmod +x ./build.sh
```

5. Run the script with your preferred option:

```bash
./build.sh [OPTIONS]
```

Available options:
```
--sideloaded: for sideloading.
--trollstore: for TrollStore users.
--rootless: for rootless jailbreaks.
--rootfull: for rootful jailbreaks.
--help: for help
```

## Using GitHub Actions

1. Fork this repository.
2. Open the "Actions" tab and enable workflows.
3. Choose "Build and Release NeoFreeBird-BHTwitter."
4. Click "Run workflow" and provide:
   - Deployment format: `rootful`, `rootless`, `sideloaded`, or `trollstore`.
   - A decrypted IPA URL for sideloaded/TrollStore builds.
   - Any value for rootful/rootless builds.
5. Check the "Releases" tab once the build completes.

# Examples

## Build for Sideloading

1. Get a decrypted IPA for Twitter/X.
2. Rename it to `com.atebits.Tweetie2.ipa` and move it to the `packages` folder.

```bash
./build.sh --sideloaded
```

Result: `NeoFreeBird-sideloaded.ipa` inside `packages`.

## Build for TrollStore

Follow the same steps as sideloading, then run:

```bash
./build.sh --trollstore
```

Result: `NeoFreeBird-trollstore.tipa` inside `packages`.

## Build for Rootless Jailbreaks

Just run:

```bash
./build.sh --rootless
```

Result: `com.bandarhl.bhtwitter_4.2_iphoneos-arm64.deb` inside `packages`.

## Build for Rootful Jailbreaks

Just run:

```bash
./build.sh --rootfull
```

Result: `com.bandarhl.bhtwitter_4.2_iphoneos-arm.deb` inside `packages`.


> [!NOTE]
> <b>These builds are considered beta</b><br>This repo is meant for NeoFreeBird, which builds this for specific versions of Twitter. You can of course build this for your own app without using the main NeoFreeBird app, but please note your build will not be supported by the NeoFreeBird team if you do.


> [!NOTE]
> <b>This repo is forked from BHTwitter.</b><br>It will merge patches upstream to BHTwitter when it's considered mostly done.

