# be-btrfs — Boot Environment Manager for btrfs

A utility for managing Boot Environments (BEs) on Linux systems with a btrfs
root filesystem. The interface is inspired by Oracle Solaris `beadm`.

Target platform: ARM SBCs (Armbian) with U-Boot, but works on any system
with a btrfs root and a bootloader that supports btrfs default subvolume.

## Requirements

- Linux with btrfs root filesystem
- Root mounted as default subvolume (no `subvol=` in fstab)
- btrfs-progs >= 6.1
- bash 5.2+
- Bootloader with btrfs support (U-Boot >= 2022.07, GRUB)

## Installation

```bash
sudo install -m 755 be-btrfs.sh /usr/local/sbin/be-btrfs
sudo cp be-btrfs.conf /etc/be-btrfs.conf
```

## Quick Start

```bash
# Check system compatibility
sudo be-btrfs check

# Create a boot environment from the current system
sudo be-btrfs create -d "before update" before-update

# Create a snapshot
sudo be-btrfs create before-update@snap1

# List environments
sudo be-btrfs list

# Activate a BE (takes effect after reboot)
sudo be-btrfs activate before-update
sudo reboot

# Switch back to the original
sudo be-btrfs activate <original-BE-name>
sudo reboot
```

## Commands

### Core (beadm-compatible)

#### create — create a BE or snapshot

```bash
# Clone the current system
sudo be-btrfs create myBE

# Clone with description and immediate activation
sudo be-btrfs create -a -d "test environment" test-env

# Clone from an existing snapshot or BE
sudo be-btrfs create -e my-snapshot newBE

# Create a read-only snapshot of a BE
sudo be-btrfs create myBE@backup
```

Options:
- `-a` — activate the BE immediately after creation
- `-d description` — attach a text description
- `-e source` — clone from a specified snapshot or BE

#### destroy — delete a BE or snapshot

```bash
sudo be-btrfs destroy myBE
sudo be-btrfs destroy myBE@backup
sudo be-btrfs destroy -F myBE          # without confirmation
sudo be-btrfs destroy -fF myBE         # + force unmount
```

Options:
- `-f` — force unmount if the BE is mounted
- `-F` — do not prompt for confirmation

#### list — list BEs and snapshots

```bash
sudo be-btrfs list                     # BEs only
sudo be-btrfs list -s                  # BEs + snapshots
sudo be-btrfs list -d                  # BEs + nested subvolumes (home, var/log, …)
sudo be-btrfs list -a                  # everything (incl. snapper, timeshift)
sudo be-btrfs list -H                  # machine-readable (semicolon-delimited)
```

Options:
- `-s` — also show snapshots (`@snap-*`)
- `-d` — show nested subvolumes (shared across all BEs)
- `-a` — show everything: BEs, snapshots, nested subvolumes, snapper, timeshift
- `-H` — machine-readable format (semicolon-delimited, no header)

Flags in output:
- `N` — active now
- `R` — active on reboot
- `NR` — both

#### activate — activate a BE

```bash
sudo be-btrfs activate myBE           # by name
sudo be-btrfs activate                 # interactive selection
```

The activated BE becomes the root filesystem on the next reboot.

#### mount / unmount — mount a BE

```bash
sudo be-btrfs mount myBE /mnt
ls /mnt/etc/
sudo be-btrfs unmount myBE
sudo be-btrfs unmount -f myBE         # force
```

Unmount options:
- `-f` — force unmount (lazy unmount)

#### rename — rename a BE

```bash
sudo be-btrfs rename old-name new-name
```

### Additional Commands

#### snapshot / clone — work with external snapshots

```bash
# Quick snapshot of the current system
sudo be-btrfs snapshot my-snap "before experiment"

# Clone from own snapshot
sudo be-btrfs clone my-snap from-snap

# Clone from snapper or timeshift (shorthand syntax)
sudo be-btrfs clone snapper#42 from-snapper
sudo be-btrfs clone timeshift/2026-03-09 from-timeshift

# Clone from any snapshot by its path on toplevel.
# You can find the path with btrfs subvolume list:
#   btrfs subvolume list / | grep snapshots
#   → ID 291 ... path @/.snapshots/ROOT.20260309T034711+0000
# The value from the "path" column is the argument for clone:
sudo be-btrfs clone @/.snapshots/ROOT.20260309T034711+0000 rollback
sudo be-btrfs clone @/.snapshots/3/snapshot from-snapper3
sudo be-btrfs clone @my-random-snap from-random
```

#### upgrade — atomic system upgrade

```bash
sudo be-btrfs upgrade
sudo be-btrfs upgrade -d "upgrade to 26.04" my-upgrade
```

Performs:
1. Snapshot of the current system (safety net)
2. Clone into a new BE
3. `apt-get update && apt-get dist-upgrade` in chroot
4. Activate the new BE

On failure the BE is not activated; you are offered to delete it.

#### shell — chroot into a BE

```bash
sudo be-btrfs shell myBE
# inside chroot: install packages, configure, etc.
exit
```

#### prune — clean up old BEs and snapshots

```bash
sudo be-btrfs prune                    # using rules from config
sudo be-btrfs prune 3                  # keep 3 newest BEs (legacy)
```

#### rescue — recover from a rescue image

```bash
# Boot from a live image, mount the btrfs partition, then:
sudo be-btrfs rescue /mnt/my-btrfs
```

#### check / status

```bash
sudo be-btrfs check                    # compatibility check
sudo be-btrfs status                   # current root and default subvolume
```

#### APT Integration

```bash
sudo be-btrfs apt-hook-install         # install the hook
# Now every apt install/upgrade automatically creates a snapshot
```

## Options Summary

| Option | Commands | Description |
|--------|----------|-------------|
| `-a` | `create` | Activate the BE immediately after creation |
| `-a` | `list` | Show everything: BEs, snapshots, snapper, timeshift |
| `-d description` | `create`, `upgrade` | Attach a text description to the BE |
| `-d` | `list` | Show nested subvolumes (shared across BEs) |
| `-e source` | `create` | Clone from a specified snapshot or BE |
| `-f` | `destroy` | Force unmount before deletion |
| `-f` | `unmount` | Force unmount (lazy unmount) |
| `-F` | `destroy` | Do not prompt for confirmation |
| `-H` | `list` | Machine-readable format (semicolon-delimited) |
| `-s` | `list` | Also show snapshots (`@snap-*`) |

## Configuration

File: `/etc/be-btrfs.conf` (system) or `~/.config/be-btrfs.conf` (user override).

```bash
# Subvolume prefixes (defaults)
#BE_PREFIX="@be-"
#SNAP_PREFIX="@snap-"

# Prune rules
# Format: "glob:min_keep:min_age"
#   glob     — subvolume name pattern
#   min_keep — minimum count to always keep
#   min_age  — do not delete younger than this
#              suffixes: h (hours), d (days), w (weeks), m (months)
#              0 = no age limit
PRUNE_RULES=(
    "@be-*:5:30d"           # BEs: keep ≥5, don't delete younger than 30 days
    "@snap-apt-*:10:7d"     # APT snapshots: ≥10, not younger than 7 days
    "@snap-*:20:30d"        # Other snapshots: ≥20, not younger than 30 days
)
```

Rules are applied top to bottom; the first match wins.
The active BE is never deleted.

## Disk Layout

```
/                         ← toplevel (subvolid=5)
├── @                     ← root filesystem (default subvolume)
├── @snap-<name>          ← read-only snapshots
├── @be-<name>            ← writable boot environments
├── .be-meta/             ← metadata
│   ├── @be-<name>.desc   ← text descriptions
│   └── previous-default  ← previous default subvolume ID (for rollback)
├── .snapshots/           ← snapper (if present)
└── timeshift-btrfs/      ← timeshift (if present)
```

## System Preparation

### fstab Requirements

The root must be mounted **without** `subvol=` or `subvolid=`:

```
UUID=xxxx-xxxx  /  btrfs  defaults,noatime  0  1
```

This allows `btrfs subvolume set-default` to control which subvolume
is mounted as root.

### Nested Subvolumes

Nested subvolumes (`@home`, `@var/log`, `@tmp`) are **not cloned** —
they remain shared across all BEs, similar to shared datasets in ZFS.
This is a deliberate MVP decision.

### Readiness Check

```bash
sudo be-btrfs check
```

## License

GPL-3.0-or-later
