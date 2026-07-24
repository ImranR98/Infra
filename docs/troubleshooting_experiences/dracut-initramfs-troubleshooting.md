# Dracut, initramfs, and kernel firmware loading — a deep dive

This document covers the concepts and debugging techniques used to
diagnose a WiFi firmware loading failure that occurred after installing
a custom dracut module (preboot FRPC + remote LUKS unlock).

## Table of contents

1. [The Linux boot sequence](#the-linux-boot-sequence)
2. [dracut: the initramfs builder](#dracut-the-initramfs-builder)
3. [Kernel firmware loading](#kernel-firmware-loading)
4. [The iwlwifi driver and firmware API versions](#the-iwlwifi-driver-and-firmware-api-versions)
5. [The bug: how a dracut module broke WiFi](#the-bug-how-a-dracut-module-broke-wifi)
6. [Debugging tools and commands](#debugging-tools-and-commands)
7. [Fixing and preventing the issue](#fixing-and-preventing-the-issue)

---

## The Linux boot sequence

When a Linux machine boots, it does not jump straight from the bootloader
to the full operating system. There is an intermediate stage called the
**initramfs** (initial RAM filesystem).

```
  Firmware → Bootloader (GRUB/systemd-boot) → Kernel → initramfs → rootfs
                                                              ↑
                                                         pivot_root
```

### What the initramfs does

The initramfs is a compressed CPIO archive (gzip/zstd) that the bootloader
loads into memory alongside the kernel. It contains a minimal Linux
environment with:

- Kernel modules needed to access the root filesystem (storage drivers,
  filesystem drivers, LUKS/dm-crypt)
- A small set of userspace tools (shell, mount, cryptsetup, etc.)
- Optional: networking support for remote LUKS unlock

The initramfs runs `/init` which:
1. Loads kernel modules for storage hardware
2. Unlocks LUKS-encrypted partitions (prompt or remote SSH)
3. Mounts the real root filesystem
4. Calls `pivot_root` (or `switch_root`) to replace the initramfs root with the real root
5. Hands control to the real `/sbin/init` (systemd)

### Why this matters for firmware

Kernel modules loaded **during** the initramfs phase can only access
firmware files that were **copied into the initramfs** at build time.
The real root filesystem is not accessible until after `pivot_root`.

If a module loads in the initramfs, fails to find firmware, and
initialises in a broken state, it **does not retry** after `pivot_root`.
The module stays loaded but non-functional.

### `rd.neednet=1` and networking in the initramfs

The kernel command-line parameter `rd.neednet=1` tells the initramfs to
bring up network interfaces before `pivot_root`. This is used for:

- Remote LUKS unlock via SSH (dropbear)
- Network-based root filesystems (NFS, iSCSI)

When `rd.neednet=1` is set, dracut includes networking tools (dhclient,
NetworkManager, etc.) and loads **all** network drivers — including
wireless drivers — during the initramfs phase.

---

## dracut: the initramfs builder

dracut is the tool used on Fedora, RHEL, and many other distributions
to build the initramfs. It is modular — each piece of functionality is
a numbered directory under `/usr/lib/dracut/modules.d/`.

### Module structure

Each module directory contains at minimum a `module-setup.sh` with:

```bash
#!/usr/bin/bash

check() {
    # Return 0 to include this module, 255 to skip
    return 0
}

depends() {
    # List other modules that must run first
    echo "network"
    return 0
}

install() {
    # Copy files, kernel modules, and firmware into the initramfs
    inst /some/file
    instmods =drivers/something
    inst_hook initqueue 10 "$moddir/my-script.sh"
}

# Optional: called after all dependencies are installed
installkernel() {
    # Install kernel modules
    instmods =drivers/virtio
}
```

Modules are processed in numeric order. Low-numbered modules (`01…`)
run first; high-numbered modules (`99…`) run last.

### Key dracut functions used in module-setup.sh

| Function | Purpose |
|----------|---------|
| `inst <src> [<dst>]` | Copy a file into the initramfs |
| `inst_dir <path>` | Create a directory in the initramfs |
| `inst_multiple <bin1> <bin2> …` | Copy binaries and their libraries |
| `instmods <pattern>` | Install kernel modules matching a pattern |
| `inst_hook <hook> <prio> <script>` | Schedule a script at a boot phase |
| `$initdir` | The root of the initramfs being built |
| `$moddir` | The dracut module's own directory |

### `instmods` and firmware resolution

`instmods` does **two** things:
1. Finds kernel modules matching the pattern (e.g., `=drivers/net/wireless`
   matches all `.ko` files under that path)
2. For each module, reads `modinfo -F firmware <module>` to discover
   firmware dependencies, then copies those firmware files from the
   host's `/lib/firmware/` into the initramfs

The firmware resolution is **exact filename matching**. If `modinfo` says
the module needs `iwlwifi-ty-a0-gf-a0-100.ucode`, dracut looks for that
exact file (and compressed variants like `.ucode.xz`, `.ucode.zst`) on
the host. If no file matches, no firmware is copied.

### dracut configuration files

Dracut reads drop-in configs from `/etc/dracut.conf.d/*.conf`. Common
directives:

```
add_dracutmodules+=" module-name "   # Force-include a module
omit_dracutmodules+=" module-name "  # Force-exclude a module
install_items+=" /path/to/file "     # Add extra files to the initramfs
```

### Building and inspecting initramfs

```bash
# Build initramfs for the current kernel
dracut --force

# Build for all installed kernels
dracut --force --regenerate-all

# List contents of an existing initramfs
lsinitrd /boot/initramfs-$(uname -r).img

# Search for specific files
lsinitrd /boot/initramfs-$(uname -r).img | grep iwlwifi
```

---

## Kernel firmware loading

### How the kernel loads firmware

When a driver needs firmware, it calls the kernel function
`request_firmware()`:

```c
int request_firmware(const struct firmware **fw, const char *name,
                     struct device *device);
```

This triggers a search through the firmware search path (default:
`/lib/firmware/`). The search logic:

1. Try the exact filename (e.g., `iwlwifi-ty-a0-gf-a0-89.ucode`)
2. If not found and `CONFIG_FW_LOADER_COMPRESS_XZ=y`, try name + `.xz`
3. If not found and `CONFIG_FW_LOADER_COMPRESS_ZSTD=y`, try name + `.zst`
4. If none found, return `-ENOENT` (error code -2)

The kernel accesses firmware through the VFS layer, meaning **symlinks
are followed**. This is how Fedora organises firmware:

```
/lib/firmware/iwlwifi-ty-a0-gf-a0-89.ucode.xz
  → intel/iwlwifi/iwlwifi-ty-a0-gf-a0-89.ucode.xz    (relative symlink)
```

And `/lib → usr/lib` (Fedora's usr-merge), so the full path resolves to
`/usr/lib/firmware/intel/iwlwifi/iwlwifi-ty-a0-gf-a0-89.ucode.xz`.

### Checking if the kernel supports compressed firmware

```bash
# The kernel config is available at /boot:
grep FW_LOADER_COMPRESS /boot/config-$(uname -r)
# Should show:
#   CONFIG_FW_LOADER_COMPRESS=y
#   CONFIG_FW_LOADER_COMPRESS_XZ=y
#   CONFIG_FW_LOADER_COMPRESS_ZSTD=y
```

### Key diagnostic: dmesg firmware messages

```bash
# View firmware-related kernel messages
dmesg | grep -i firmware
journalctl -k | grep -i firmware
```

A failure looks like:
```
iwlwifi 0000:a6:00.0: Direct firmware load for iwlwifi-ty-a0-gf-a0-89.ucode failed with error -2
```

Error code -2 is `ENOENT` ("No such file or directory"). This means the
kernel could not find the firmware file *at the time the driver loaded*.

---

## The iwlwifi driver and firmware API versions

### Firmware naming convention

Intel WiFi firmware files follow a strict naming pattern:

```
iwlwifi-<device-id>-<api-version>.ucode
iwlwifi-ty-a0-gf-a0-89.ucode    ← example
```

- **Device ID** (e.g., `ty-a0-gf-a0`): identifies the WiFi chipset
  (Intel AX210 in this case)
- **API version** (e.g., `89`): the firmware interface version

There is also a **PNVM** file (Platform NVM) per chipset:
```
iwlwifi-ty-a0-gf-a0.pnvm
```

### How the driver selects firmware

The iwlwifi driver is compiled with a **maximum API version** baked in.
At runtime:

1. Driver calls `request_firmware()` starting at the max API version
   (e.g., `iwlwifi-ty-a0-gf-a0-100.ucode`)
2. If that fails, it decrements the version and tries again
3. It repeats until it finds firmware or runs out of versions

The max API version is listed in `modinfo`:
```bash
modinfo iwlwifi | grep firmware | grep ty-a0
# Output: firmware: iwlwifi-ty-a0-gf-a0-100.ucode
```

### The version mismatch problem

The kernel (iwlwifi driver) may be compiled to support API version **100**,
but the installed `linux-firmware` package may only provide version **89**
(as the highest available). This is *normally* fine because the driver
falls back. But it becomes a problem in the initramfs (see below).

---

## The bug: how a dracut module broke WiFi

### The setup

A custom dracut module (`99wifi-net`) was installed on the system. It:

1. Added `add_dracutmodules+=" network-manager "` to dracut config
2. Included `instmods =drivers/net/wireless` to copy WiFi modules
3. Depended on the `network-manager` dracut module

The `install-preboot` command also added `rd.neednet=1 ip=dhcp` to the
kernel command line (via the `crypt-ssh` installer), telling the initramfs
to bring up networking early.

### The chain of failure

```
1. Boot starts
   └→ Kernel loads initramfs

2. rd.neednet=1 triggers network initialisation in initramfs
   └→ NetworkManager starts
   └→ udev probes WiFi hardware
   └→ iwlwifi module loads (from initramfs's copy of the .ko)

3. iwlwifi calls request_firmware("iwlwifi-ty-a0-gf-a0-100.ucode")
   └→ Not in initramfs (dracut never copied it)
   └→ Driver falls back to -89, then -86, etc.
   └→ None found in initramfs
   └→ "Direct firmware load failed with error -2"

4. iwlwifi module is loaded but non-functional
   └→ No wlan0 interface appears

5. pivot_root swaps to real root filesystem
   └→ Real /lib/firmware/ has the firmware files
   └→ But iwlwifi already initialised and failed
   └→ Driver does NOT retry firmware loading

6. WiFi is dead on every subsequent boot
```

### Why dracut didn't copy the firmware

`instmods =drivers/net/wireless` copies the iwlwifi `.ko` module and
tries to resolve firmware via `modinfo`:

```
modinfo -F firmware iwlwifi
# → iwlwifi-ty-a0-gf-a0.pnvm
# → iwlwifi-ty-a0-gf-a0-100.ucode
# → iwlwifi-7265D-29.ucode
# → ⋯
```

For the AX210 chipset, dracut looks for `iwlwifi-ty-a0-gf-a0-100.ucode`
(and `*.ucode.xz`, `*.ucode.zst`). But the host only has up to version
`-89` on disk. No file matches → **no firmware is copied to the initramfs**.

The PNVM file (`iwlwifi-ty-a0-gf-a0.pnvm.xz`) *is* found and copied,
because it has no version number. But the actual firmware binary is
missing from the initramfs.

### Why decompressing the firmware to a plain .ucode file worked (temporarily)

Creating `/lib/firmware/iwlwifi-ty-a0-gf-a0-89.ucode` (uncompressed)
made it available on the *real root filesystem*. Reloading the module
(`modprobe -r iwlwifi; modprobe iwlwifi`) worked because the module
loaded **after** pivot_root and found the firmware.

But after a reboot, the module loaded **during** the initramfs phase
(because of `rd.neednet=1`), and the initramfs still didn't have the
firmware. Same failure.

### The permanent fix in the dracut module

After `instmods`, the module now explicitly installs all available
firmware for every wireless module included in the initramfs:

```bash
for mod in $(find "$initdir" -path "*/drivers/net/wireless/*.ko*" \
             -printf '%f\n' | sed 's/\.ko.*//' | sort -u); do
    for fw in $(modinfo -F firmware "$mod" 2>/dev/null); do
        # Strip API version suffix to get the device prefix
        prefix="${fw%.ucode}"
        prefix="${prefix%.pnvm}"
        prefix="${prefix%-[0-9]*}"
        prefix="${prefix%-c[0-9]*}"
        # Install all firmware matching this prefix
        for f in /lib/firmware/"${prefix}"*; do
            [ -f "$f" ] && inst "$f"
        done
    done
done
```

This walks every wireless `.ko` in the initramfs, extracts the firmware
device prefix from `modinfo` (e.g., `iwlwifi-ty-a0-gf-a0-100.ucode` →
`iwlwifi-ty-a0-gf-a0`), and installs **all** firmware files matching
that prefix — regardless of API version. The driver's built-in fallback
then finds the highest available version at boot time.

---

## Debugging tools and commands

### Identifying hardware

```bash
# List PCI network devices with vendor/device IDs
lspci -nn | grep -i net

# USB network devices
lsusb | grep -i net
```

### Checking loaded modules

```bash
# Is the iwlwifi module loaded?
lsmod | grep iwl

# Module details including firmware dependencies
modinfo iwlwifi | grep -E "firmware|depends|description"
modinfo iwlwifi | grep firmware | wc -l    # how many firmware files
```

### Checking firmware files on disk

```bash
# List firmware for a specific chipset
ls -la /lib/firmware/iwlwifi-ty-a0-gf-a0*

# Check if a file is an actual file or a symlink
file /lib/firmware/iwlwifi-ty-a0-gf-a0-89.ucode.xz
readlink -f /lib/firmware/iwlwifi-ty-a0-gf-a0-89.ucode.xz

# Verify the file is a valid XZ archive
file /lib/firmware/intel/iwlwifi/iwlwifi-ty-a0-gf-a0-89.ucode.xz
# → "XZ compressed data, checksum CRC32"
```

### Checking which RPM owns a file

```bash
# What package provides this file?
rpm -qf /lib/firmware/iwlwifi-ty-a0-gf-a0-89.ucode.xz
rpm -qf /lib/firmware/intel/iwlwifi/iwlwifi-ty-a0-gf-a0-89.ucode.xz

# List all files in a package
rpm -ql iwlwifi-mvm-firmware

# Verify package integrity (no output = all files intact)
rpm -V iwlwifi-mvm-firmware
rpm -V dracut
```

### Checking the boot sequence

```bash
# Kernel messages from the current boot
dmesg | grep -iE "iwlwifi|firmware|mount"

# Kernel messages from all boots (persistent journal)
journalctl -k --no-pager | grep -i iwlwifi

# Previous boot
journalctl -k -b -1 --no-pager | grep -i iwlwifi

# Check what ran when (timeline)
journalctl -k --no-pager | grep -E "iwlwifi|pivot_root|mount.*root"

# Check the running kernel command line
cat /proc/cmdline
```

### Inspecting the initramfs

```bash
# List contents (requires root to read /boot/initramfs-*.img)
sudo lsinitrd /boot/initramfs-$(uname -r).img | grep iwlwifi

# Check if firmware was included
sudo lsinitrd /boot/initramfs-$(uname -r).img | grep -c iwlwifi

# Check permissions (initramfs files are often 0600)
ls -la /boot/initramfs-*
```

### Checking kernel configuration

```bash
# Firmware compression support
grep FW_LOADER_COMPRESS /boot/config-$(uname -r)

# iwlwifi driver options
grep IWLWIFI /boot/config-$(uname -r)
```

### Working with dracut

```bash
# List all dracut modules
ls /usr/lib/dracut/modules.d/

# List custom dracut modules
ls /usr/lib/dracut/modules.d/99*/

# List dracut config files
cat /etc/dracut.conf.d/*.conf

# Rebuild initramfs
dracut --force                          # current kernel only
dracut --force --regenerate-all         # all installed kernels

# Rebuild silently (suppress warnings)
dracut --force --regenerate-all 2>/dev/null
```

### Checking GRUB and kernel command line

```bash
# GRUB config
cat /etc/default/grub

# BLS (Boot Loader Specification) entries
ls /boot/loader/entries/
cat /boot/loader/entries/*.conf

# Add cmdline args to all kernels (grubby is idempotent — safe to re-run)
sudo grubby --update-kernel=ALL --args="rd.neednet=1 ip=dhcp"
```

### RPM troubleshooting

```bash
# What packages are installed for firmware?
rpm -qa | grep firmware

# When was a package installed or upgraded?
rpm -qa --last | grep linux-firmware

# Did a package's files change since installation?
rpm -V dracut-crypt-ssh

# Reinstall a package (restores deleted or corrupted files)
sudo dnf reinstall dracut -y
sudo dnf reinstall dracut-crypt-ssh -y

# Check DNF transaction history
cat /var/log/dnf5.log | grep -E "linux-firmware|kernel|dracut"
```

### Network diagnostics

```bash
# List network interfaces
ip link show

# Check rfkill (radio kill switch)
rfkill list

# Check NetworkManager status
systemctl status NetworkManager

# Check which DNS/resolver is active
resolvectl status
```

---

## Fixing and preventing the issue

### Immediate fix (broken machine, no WiFi)

1. Get internet via USB tethering or Ethernet cable
2. Create uncompressed firmware as a stopgap:
   ```bash
   xz -d -c /lib/firmware/iwlwifi-ty-a0-gf-a0-89.ucode.xz | \
     sudo tee /lib/firmware/iwlwifi-ty-a0-gf-a0-89.ucode > /dev/null
   sudo modprobe -r iwlwifi; sudo modprobe iwlwifi
   ```
3. Run `sudo dnf upgrade` to get any fixed firmware package
4. Rebuild initramfs: `sudo dracut --force --regenerate-all`

### Permanent fix (prevent recurrence)

The root cause was that `instmods =drivers/net/wireless` copies wireless
driver modules into the initramfs but can miss firmware when the
`modinfo` firmware list and the installed firmware package disagree on
the API version.

The fix (committed to `dracut-remote-luks-unlock`): after `instmods`,
explicitly install all available firmware matching each wireless
module's firmware prefixes, handling the API version mismatch.

### Checklist for adding initramfs networking

When adding any dracut module that enables networking in the initramfs:

1. Verify firmware is actually included: `lsinitrd | grep firmware`
2. Test with a reboot — does the driver find firmware in the initramfs?
3. If using `instmods`, verify firmware resolution handles API version
   mismatches between the kernel (`modinfo`) and the installed firmware
   package
4. Any module that depends on networking should have a timeout for the
   `net.ready` signal so it doesn't hang the boot
5. Kernel cmdline changes should be applied idempotently (use `grubby`
   unconditionally, not conditional on `/proc/cmdline`)

---

## Key lessons

1. **The initramfs is a separate world.** Files on the real root filesystem
   don't exist in the initramfs. Everything needed during the initramfs
   phase must be explicitly copied in at build time.

2. **`instmods` firmware resolution is fragile.** It depends on exact
   filename matching between `modinfo` output and files on disk. When the
   kernel's firmware API version exceeds what's in the firmware package,
   no firmware is copied for that module.

3. **Drivers don't retry firmware loads.** If a module loads in the
   initramfs and fails firmware initialisation, it stays in that broken
   state even after the real root is mounted.

4. **Use `lsinitrd` to verify.** After any dracut config change, inspect
   the initramfs to confirm the right files are included.

5. **`rpm -V` is the fastest way to check for tampering.** It verifies
   every file owned by a package against the RPM database. No output means
   all files are intact.

6. **`rpm -qf` tells you who owns a file.** Essential for understanding
   whether a file belongs to a package or was manually placed.
