# NothingMuchMore — Nothing Phone (2) / Pong

Continuation of [arter97](https://github.com/arter97)'s **NothingMuchROM** for the
Nothing Phone (2), rebased onto **Nothing OS 4.1**.

All original work is arter97's; this fork exists because upstream development
stopped after r40 (Nothing OS 4.0, build 260226). The name is his — *NothingMuch*,
just a bit more of it.

Maintained by **sappy** ([ShaptakNaskar](https://github.com/ShaptakNaskar)).

- ROM: [ShaptakNaskar/nothingmuchmore](https://github.com/ShaptakNaskar/nothingmuchmore)
- Kernel: [ShaptakNaskar/nothingmuchmore_kernel_sm8475](https://github.com/ShaptakNaskar/nothingmuchmore_kernel_sm8475)

Flashing uses [nothing_flasher](https://github.com/spike0en/nothing_flasher) by
[Spike](https://github.com/spike0en).

## What this is

Not an AOSP ROM — it repacks **stock Nothing OS** at the filesystem level:
mount the stock dynamic partitions, debloat (`remove.txt`), overlay changes
(`files/`, `append/`, `overlay/`), run tweak scripts (`plugins/`), then rebuild
`super.img` with `lpmake`. No device tree needed; no Android source build.

## Current release: r41 (Nothing OS 4.1, build 260618)

Carried over from arter97's r40:
- Debloat, AOSPA LMKD, patched bionic, `msm_irqbalance`, jemalloc zero-fill on camera
- 64-bit-only (`64bo`), Google Sans + framework overlay, DPI 360, 30-step volume + Dirac fix
- Display/logd/NFC tweaks

Changed for 4.1:
- **64-bit WebView** — arter97's bundled `WebViewGoogle64` ships a *32-bit*
  `libmonochrome_64.so`, unusable in a 64-bit-only ROM (GMS crash-loop). Now uses
  the stock 4.1 WebView, which has a real `lib/arm64-v8a/libmonochrome.so`.
- **Chrome removed** — Nothing's Chrome is 32-bit via the Trichrome shared library,
  so it crash-loops under `64bo`. Install from Play instead.
- **[BCR](https://github.com/chenxiaolong/BCR) bundled** as a `product` priv-app
  (call recording), with its privapp-permissions whitelist.
- Build fixes for modern hosts: bionic symlink `ELOOP` tolerance, erofs for
  system/system_ext/vendor (4.1 outgrew arter97's ext4 caps), `run-parts` replaced,
  `apktool 2.9.3` + `apksigner` for the overlay.

## Building it yourself

Everything below assumes Linux, **root** (make.sh loop-mounts the stock images),
~150 GB free disk, and an SSD if you value your time.

### 1. Install the tools

Arch / CachyOS:

```bash
sudo pacman -S --needed android-tools erofs-utils e2fsprogs rsync attr acl \
                        pigz bc flex bison ccache python jdk-openjdk unzip curl
paru -S payload-dumper-go            # or: go install github.com/ssut/payload-dumper-go@latest
```

Debian / Ubuntu: `android-sdk-libsparse-utils erofs-utils e2fsprogs rsync attr acl
pigz bc flex bison ccache default-jdk unzip curl` (you also need `lpmake` — build it
from AOSP `system/extras/partition_tools` or grab a prebuilt).

Check you have these on PATH: `lpmake`, `mkfs.erofs`, `mkfs.ext4`, `fsck.erofs`,
`setfacl`, `setfattr`, `pigz`, `payload-dumper-go`.

For the framework overlay (optional, see step 5) you also need:
- **apktool 2.9.3** (the project uses the old `apktool.yml` schema; 3.x cannot read it)
  ```bash
  curl -L -o ~/apktool_2.9.3.jar \
    https://github.com/iBotPeaches/Apktool/releases/download/v2.9.3/apktool_2.9.3.jar
  ```
- **apksigner** + **zipalign** from Android build-tools, and the AOSP platform testkey:
  ```bash
  mkdir -p ../keys && cd ../keys
  curl -s "https://android.googlesource.com/platform/build/+/refs/heads/main/target/product/security/testkey.pk8?format=TEXT" | base64 -d > testkey.pk8
  curl -s "https://android.googlesource.com/platform/build/+/refs/heads/main/target/product/security/testkey.x509.pem?format=TEXT" | base64 -d > testkey.x509.pem
  ```

You also need AOSP's `avbtool`, which make.sh expects at `../avb/avbtool.py`:

```bash
cd ..  &&  git clone --depth 1 https://android.googlesource.com/platform/external/avb
```

### 2. Get a stock Nothing OS 4.1 dump

Download the full OTA zip for **Pong** (this ROM is built against
`Pong-B4.1-260618`), then extract the partition images:

```bash
payload-dumper-go -o stock/ Pong_B4.1-260618.zip
```

You need the six dynamic partitions: `system system_ext product vendor odm vendor_dlkm`.
Put them (or symlinks) in one directory, e.g. `~/pong/dyn-4.1/`.

### 3. Extract the proprietary WebView

The stock 64-bit WebView and Trichrome library are **not** in this repo (Google-signed
binaries, and WebView is >100 MB). Pull them from your own dump:

```bash
scripts/extract_stock_webview.sh /path/to/stock/product.img
```

This drops them into `files/product/app/{WebViewGoogle64,TrichromeLibrary64}/`.
Verify the WebView lib is `lib/arm64-v8a/libmonochrome.so` — a 32-bit one will
crash-loop GMS on this 64-bit-only ROM.

### 4. Point make.sh at your dump

```bash
sed -i 's|^STOCK_FIRMWARE=.*|STOCK_FIRMWARE=/home/you/pong/dyn-4.1|' make.sh
```

Sanity-check the sizes near the top of `make.sh`:

```
SYSTEM_SIZE=1600        # ext4  - do NOT set to 0/erofs, see Notes
SYSTEM_EXT_SIZE=1400    # ext4  - same
PRODUCT_SIZE=0          # 0 = erofs (compressed)
VENDOR_SIZE=0           # 0 = erofs
ODM_SIZE=2
VENDOR_DLKM_SIZE=45
```

Total must fit `SUPER_SIZE` (7168 MiB). If a partition overflows you will see
`Could not allocate block in ext2 filesystem` — raise that size, or lower another.

### 5. (Optional) the framework overlay

`plugins/overlay` rebuilds `arter97FrameworksOverlay` (Google Sans, long-press power,
profile colors). Adjust the paths at the top of that script to your apktool jar,
build-tools and keys, or drop `plugins/overlay` from the loop in `make.sh` to skip it.

### 6. Build

```bash
sudo ./make.sh
```

Output is `out/super.img` (~6.5 GB sparse). The build mounts the stock images
read-only, rsyncs them minus `remove.txt`, overlays `files/` + `append/`, restores
file attrs/contexts, runs `plugins/`, makes the filesystems and packs everything
with `lpmake`.

Handy checks afterwards:

```bash
xxd -l4 -p out/super.img                 # 3aff26ed = valid Android sparse image
dump.erofs --path=/app/WebViewGoogle64/WebViewGoogle64.apk out/product.img
```

## Flashing

**`super` must be flashed from fastbootd**, not the bootloader — from the bootloader
it fails with `Writing 'super' FAILED (remote: 'No such file or directory')`.
`boot`, `vbmeta` and firmware flash fine from either.

```bash
adb reboot fastboot                      # fastbootd; verify: fastboot getvar is-userspace
fastboot flash super out/super.img
fastboot -w                              # required on first install, see below
fastboot reboot
```

If a direct `flash super` fails (wrong active slot, pending OTA snapshot), use
Spike's [nothing_flasher](https://github.com/spike0en/nothing_flasher) — drop
`super.img` (and your `boot.img`) next to its `flash_all.sh` and run it. It sets
slot A, reboots into fastbootd itself and retries, so it handles the cases a bare
`fastboot flash super` trips over.

Verified boot must stay disabled, so coming from stock also flash:

```bash
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
```

### A data wipe is required on first install

Coming from stock or arter97's r40, **wipe data** (`fastboot -w`, or answer Y to
"Wipe Data?" in [nothing_flasher](https://github.com/spike0en/nothing_flasher)). The WebView package changes identity between those builds and
Android's package cache will not re-scan it, giving:

```
UnsatisfiedLinkError: dlopen failed: library "libmonochrome_64.so" not found
```

…and Google Play crash-loops. If you already dirty-flashed, either wipe or try
`su -c "rm -rf /data/system/package_cache/*"` and reboot.

**Keep your stock images** — the Phone (2) has no public EDL recovery.

## Notes

- **Do not convert `system` / `system_ext` to erofs.** NOS 4.1 outgrew arter97's
  original ext4 caps, and the obvious fix — switching them to compressed erofs —
  breaks FUSE storage on SUSFS-patched kernels: MediaProvider's FuseDaemon fails
  with `failed to stat source /storage/emulated`, every app then reports no storage
  / no sdcard, and `adb push` fails. Keep them ext4 and raise the sizes instead;
  `vendor` / `product` are fine as erofs.
- **64-bit-only (`64bo`) is inherited from arter97 and currently required by this
  build.** It sets `ro.zygote=zygote64` and empties `abilist32`, which is why stock
  Chrome (32-bit via Trichrome) is removed and the WebView must be the arm64 build.
  Disabling `64bo` is not a one-line change: it needs `init.zygote64_32.rc` kept in
  `remove.txt`, more space for the 32-bit libs, and a rebuild of the WebView/Chrome
  choices. An attempt here failed to boot with
  `CANNOT LINK EXECUTABLE /system/bin/app_process32: library "libntf.so" not found`,
  but that was never root-caused — stock 4.1 *does* ship 32-bit `libntf.so`
  (`system_ext/lib/`, `vendor/lib/`), so 32-bit support is probably achievable with
  some work. Untested; patches welcome.
- The large WebView/Trichrome APKs are gitignored; use `scripts/extract_stock_webview.sh`.
- Kernel is a separate project — this repo is userspace only. Any KernelSU/SUSFS
  kernel for Pong works; the ROM does not depend on one.
