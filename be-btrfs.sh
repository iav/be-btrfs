#!/bin/bash
# be-btrfs — Boot Environment manager for btrfs
# Designed for Armbian/Debian/Ubuntu on ARM SBCs with U-Boot
# Requires: btrfs-progs >= 6.1, util-linux (findmnt)
# Compatible with: bash 5.2+ (Ubuntu Noble / Debian Trixie)
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

readonly PROG="${0##*/}"
readonly VERSION="0.4.0"

# --- Defaults (overridden by config) ---

BE_PREFIX="@be-"
SNAP_PREFIX="@snap-"
META_DIR=".be-meta"
TOPLEVEL_MOUNT="/run/be-toplevel"

PRUNE_RULES=(
    "@be-*:5:30d"
    "@snap-apt-*:10:7d"
    "@snap-*:20:30d"
)

# --- Config loading ---

_load_config() {
    local f
    for f in /etc/be-btrfs.conf ~/.config/be-btrfs.conf; do
        # shellcheck source=/dev/null
        if [[ -f "$f" ]]; then . "$f"; fi
    done
}

# --- Output ---

if [[ -t 1 ]]; then
    _B='\033[1m' _G='\033[32m' _Y='\033[33m' _R='\033[31m' _0='\033[0m'
else
    _B='' _G='' _Y='' _R='' _0=''
fi

if command -v logger &>/dev/null; then
    _log() { logger -t be-btrfs "$*"; }
else
    _log() { :; }
fi

die()  { printf "${_R}error:${_0} %s\n" "$*" >&2; _log "ERROR: $*"; exit 1; }
warn() { printf "${_Y}warning:${_0} %s\n" "$*" >&2; }
info() { printf "${_G}::${_0} %s\n" "$*"; _log "$*"; }

# --- Common checks ---

need_root() {
    [[ $EUID -eq 0 ]] || die "root required (use sudo)"
}

need_btrfs() {
    local fstype
    fstype=$(findmnt -n -o FSTYPE /)
    [[ "$fstype" == "btrfs" ]] || die "root filesystem is not btrfs (found: $fstype)"
}

# Verify that root is mounted as the default subvolume,
# otherwise set-default will have no effect on reboot.
check_mount_opts() {
    # Check fstab, not runtime mount options —
    # the kernel always shows subvol=/subvolid= in mount output, even when
    # not specified in fstab (i.e. mounted by default subvolume).
    local fstab_opts
    fstab_opts=$(findmnt -n -o OPTIONS --fstab /) || return 0

    if [[ "$fstab_opts" =~ subvol=([^,]+) ]]; then
        local sv="${BASH_REMATCH[1]}"
        [[ "$sv" == "/" ]] && return 0
        die "fstab has subvol=${sv} for /
  Boot environments require mounting by default subvolume.
  Remove the subvol= option from /etc/fstab and reboot."
    fi

    if [[ "$fstab_opts" =~ subvolid=([0-9]+) ]]; then
        local sid="${BASH_REMATCH[1]}"
        [[ "$sid" == "0" || "$sid" == "5" ]] && return 0
        die "fstab has subvolid=${sid} for / (not default).
  Remove the subvolid= option from /etc/fstab and reboot."
    fi
}

# --- Toplevel (subvolid=5) management ---

_tl=""
_tl_owned=false

mount_toplevel() {
    if [[ -n "$_tl" ]]; then
        return
    fi
    if mountpoint -q "$TOPLEVEL_MOUNT" 2>/dev/null; then
        _tl="$TOPLEVEL_MOUNT"
        return
    fi
    local dev
    dev=$(root_dev)
    mkdir -p "$TOPLEVEL_MOUNT"
    mount -o subvolid=5 "$dev" "$TOPLEVEL_MOUNT"
    _tl="$TOPLEVEL_MOUNT"
    _tl_owned=true
}

cleanup() {
    if $_tl_owned && mountpoint -q "$TOPLEVEL_MOUNT" 2>/dev/null; then
        umount "$TOPLEVEL_MOUNT" 2>/dev/null || true
        rmdir "$TOPLEVEL_MOUNT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

root_dev() { findmnt -n -o SOURCE / | sed 's/\[.*//'; }

default_id() { btrfs subvolume get-default / | awk '{print $2}'; }

# Path of current root on toplevel (e.g. "@" or "@be-upgrade").
current_root_path() {
    btrfs subvolume show / 2>/dev/null | awk '/^\tName:/ {print $2}'
}

# Full path to current root on mounted toplevel.
_current_root_dir() {
    local crp
    crp=$(current_root_path)
    if [[ -n "$crp" ]]; then
        echo "$_tl/$crp"
    else
        echo "$_tl"
    fi
}

subvol_id_of() {
    btrfs subvolume show "$1" 2>/dev/null | awk '/Subvolume ID:/ {print $3}'
}

timestamp() { date -u +%Y%m%dT%H%M%SZ; }

# --- Metadata ---

meta_set() {
    local name="$1" desc="$2"
    mkdir -p "$_tl/$META_DIR"
    printf '%s\n' "$desc" > "$_tl/$META_DIR/${name}.desc"
}

meta_get() {
    local f="$_tl/$META_DIR/${1}.desc"
    [[ -f "$f" ]] && cat "$f" || true
}

# --- Common subvolume primitives ---

# Create a read-only snapshot.
# Usage: _make_snapshot <src_path> <svname> [desc]
_make_snapshot() {
    local src="$1" svname="$2" desc="${3:-}"
    [[ -d "$_tl/$svname" ]] && die "snapshot '${svname}' already exists"
    btrfs subvolume snapshot -r "$src" "$_tl/$svname" >/dev/null
    [[ -n "$desc" ]] && meta_set "$svname" "$desc"
}

# Check fstab inside a clone for hardcoded subvol=/subvolid= on /.
# Such entries would prevent the clone from booting correctly.
_check_clone_fstab() {
    local path="$1"
    local fstab="$path/etc/fstab"
    [[ -f "$fstab" ]] || return 0
    local line
    while IFS= read -r line; do
        # Skip comments and non-root entries
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ [[:space:]]/[[:space:]] ]] || continue
        if [[ "$line" =~ subvol=([^,[:space:]]+) ]]; then
            local sv="${BASH_REMATCH[1]}"
            [[ "$sv" == "/" ]] && continue
            warn "clone's /etc/fstab has subvol=${sv} for / — this will prevent correct boot."
            warn "Edit $fstab and remove the subvol= option, or use 'be-btrfs shell' to fix it."
        fi
        if [[ "$line" =~ subvolid=([0-9]+) ]]; then
            local sid="${BASH_REMATCH[1]}"
            [[ "$sid" == "0" || "$sid" == "5" ]] && continue
            warn "clone's /etc/fstab has subvolid=${sid} for / — this will prevent correct boot."
            warn "Edit $fstab and remove the subvolid= option, or use 'be-btrfs shell' to fix it."
        fi
    done < "$fstab"
}

# Create a writable clone (BE).
# Usage: _make_clone <src_path> <bename> [desc]
_make_clone() {
    local src="$1" bename="$2" desc="${3:-}"
    [[ -d "$_tl/$bename" ]] && die "boot environment '${bename#${BE_PREFIX}}' already exists"
    btrfs subvolume snapshot "$src" "$_tl/$bename" >/dev/null
    meta_set "$bename" "$desc"
    _check_clone_fstab "$_tl/$bename"
}

# Find actual mountpoint of a subvolume by its name.
# Returns empty string if not mounted.
_find_mountpoint() {
    local svname="$1"
    findmnt -ln -o TARGET,SOURCE -t btrfs \
        | while read -r tgt src; do
            [[ "$src" == *"[/${svname}]" ]] && echo "$tgt" && break
        done
}

# Iterator over btrfs subvolume list: calls callback with args (id, svname).
# Usage: _iter_subvols <path> <callback> [--sort=gen]
_iter_subvols() {
    local path="$1" callback="$2"
    shift 2
    while IFS= read -r line; do
        local id svname
        id=$(awk '{print $2}' <<< "$line")
        svname=$(awk '{print $NF}' <<< "$line")
        "$callback" "$id" "$svname"
    done < <(btrfs subvolume list "$@" "$path")
}

# Interactive BE selection menu.
# Usage: _choose_be <path> [did]
# Prints selected BE name (without prefix) to stdout.
_choose_be() {
    local path="$1" did="${2:-}"
    local -a names=() ids=()

    _chooser_cb() {
        local id="$1" svname="$2"
        [[ "$svname" == ${BE_PREFIX}* ]] || return 0
        local display="${svname#${BE_PREFIX}}"
        local mark=""
        [[ -n "$did" && "$id" == "$did" ]] && mark=" (active)"
        local desc
        desc=$(meta_get "$svname")
        [[ -n "$desc" ]] && desc=" — $desc"
        names+=("$display")
        ids+=("$id")
        printf "  %d) %s%s%s\n" "${#names[@]}" "$display" "$mark" "$desc"
    }

    _iter_subvols "$path" _chooser_cb

    [[ ${#names[@]} -gt 0 ]] || die "no boot environments found"

    echo
    read -rp "Choose (1-${#names[@]}): " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )) \
        || die "invalid choice"

    local idx=$((choice - 1))
    printf '%s\n' "${names[$idx]}"
}

# --- BE mount for chroot ---

_be_resolv_backup=""

_be_mount() {
    local bename="$1" mnt="$2"
    local dev
    dev=$(root_dev)
    mkdir -p "$mnt"
    mount -o "subvol=${bename}" "$dev" "$mnt"
    mount --bind /proc "$mnt/proc"
    mount --bind /sys  "$mnt/sys"
    mount --bind /dev  "$mnt/dev"
    mount --bind /dev/pts "$mnt/dev/pts"
    # Chroot needs real DNS servers, not the stub 127.0.0.53.
    # resolv.conf in the clone may be a symlink to systemd-resolved —
    # save the original, replace with upstream DNS file.
    _be_resolv_backup=""
    if [[ -L "$mnt/etc/resolv.conf" ]]; then
        _be_resolv_backup=$(readlink "$mnt/etc/resolv.conf")
        rm -f "$mnt/etc/resolv.conf"
    fi
    if [[ -f /run/systemd/resolve/resolv.conf ]]; then
        cp /run/systemd/resolve/resolv.conf "$mnt/etc/resolv.conf" 2>/dev/null || true
    elif [[ -f /etc/resolv.conf ]]; then
        cp --dereference /etc/resolv.conf "$mnt/etc/resolv.conf" 2>/dev/null || true
    fi
}

_be_umount() {
    local mnt="$1"
    # Restore original resolv.conf (symlink to systemd-resolved)
    if [[ -n "${_be_resolv_backup:-}" ]]; then
        rm -f "$mnt/etc/resolv.conf"
        ln -s "$_be_resolv_backup" "$mnt/etc/resolv.conf"
    fi
    for p in dev/pts dev sys proc; do
        umount -l "$mnt/$p" 2>/dev/null || true
    done
    umount -l "$mnt" 2>/dev/null || true
    rmdir "$mnt" 2>/dev/null || true
}

# Run a command in a chroot BE with guaranteed cleanup.
# Usage: _with_mounted_be <bename> <command...>
# Returns the command's exit code.
_with_mounted_be() {
    local bename="$1"; shift
    local name="${bename#${BE_PREFIX}}"
    local mnt="/run/be/${name}"
    _be_mount "$bename" "$mnt"

    local rc=0
    # Trap ensures cleanup on Ctrl+C, set -e, or any abort
    trap '_be_umount "'"$mnt"'"; trap - INT TERM' INT TERM
    "$@" "$mnt" || rc=$?
    trap - INT TERM
    _be_umount "$mnt"
    return $rc
}

# Resolve source path for clone/create -e.
# Supports: @snap-*, @be-*, snapper#N, timeshift/<date>, toplevel path
_resolve_source() {
    local source="$1"

    if [[ "$source" == snapper#* ]]; then
        echo "$_tl/.snapshots/${source#snapper#}/snapshot"
    elif [[ "$source" == timeshift/* ]]; then
        echo "$_tl/timeshift-btrfs/snapshots/${source#timeshift/}/@"
    elif [[ -d "$_tl/${SNAP_PREFIX}${source}" ]]; then
        echo "$_tl/${SNAP_PREFIX}${source}"
    elif [[ -d "$_tl/${BE_PREFIX}${source}" ]]; then
        echo "$_tl/${BE_PREFIX}${source}"
    elif [[ -d "$_tl/${source}" ]]; then
        echo "$_tl/${source}"
    else
        return 1
    fi
}

# --- Commands ---

# beadm create [-a] [-d description] [-e source] name
# beadm create name@snapshot
cmd_create() {
    need_root; need_btrfs; mount_toplevel

    local do_activate=false
    local desc=""
    local source=""
    local OPTIND=1

    while getopts ":ad:e:" opt; do
        case "$opt" in
            a) do_activate=true ;;
            d) desc="$OPTARG" ;;
            e) source="$OPTARG" ;;
            :) die "option -$OPTARG requires an argument" ;;
            *) die "unknown option: -$OPTARG" ;;
        esac
    done
    shift $((OPTIND - 1))

    local name="${1:?specify BE name}"

    # create name@snapshot — create a snapshot (like beadm create BE1@now)
    if [[ "$name" == *@* ]]; then
        local be_part="${name%%@*}"
        local snap_part="${name#*@}"
        [[ -n "$snap_part" ]] || die "specify snapshot name after @"

        local src
        if [[ -z "$be_part" ]]; then
            src=$(_current_root_dir)
        else
            local bename="${BE_PREFIX}${be_part}"
            [[ -d "$_tl/$bename" ]] || die "boot environment '$be_part' not found"
            src="$_tl/$bename"
        fi

        local svname="${SNAP_PREFIX}${be_part:+${be_part}-}${snap_part}"
        _make_snapshot "$src" "$svname" "$desc"
        info "Snapshot created: ${be_part:+${be_part}-}${snap_part}"
        return
    fi

    # create [-e source] name — create a BE (clone)
    local bename="${BE_PREFIX}${name}"

    local sp=""
    if [[ -n "$source" ]]; then
        sp=$(_resolve_source "$source") || die "source '$source' not found"
    else
        sp=$(_current_root_dir)
    fi

    [[ -z "$desc" ]] && desc="clone of ${source:-$(current_root_path)}"
    _make_clone "$sp" "$bename" "$desc"
    info "Boot environment created: $name"

    if $do_activate; then
        cmd_activate "$name"
    fi
}

# beadm destroy [-fF] name | name@snapshot
cmd_destroy() {
    need_root; mount_toplevel

    local force_umount=false
    local no_confirm=false
    local OPTIND=1

    while getopts ":fF" opt; do
        case "$opt" in
            f) force_umount=true ;;
            F) no_confirm=true ;;
            *) die "unknown option: -$OPTARG" ;;
        esac
    done
    shift $((OPTIND - 1))

    local name="${1:?specify BE name or snapshot (name@snap)}"

    # destroy name@snapshot — maps name to @snap-name-snapshot
    # (matches how create name@snap creates snapshots)
    if [[ "$name" == *@* ]]; then
        local be_part="${name%%@*}"
        local snap_part="${name#*@}"
        local snap_name="${be_part:+${be_part}-}${snap_part}"
        local svname="${SNAP_PREFIX}${snap_name}"
        [[ -d "$_tl/$svname" ]] || die "snapshot '$snap_name' not found"

        if ! $no_confirm; then
            read -rp "Delete snapshot '$snap_name'? [y/N] " yn
            [[ "$yn" =~ ^[Yy]$ ]] || return 0
        fi

        btrfs subvolume delete "$_tl/$svname" >/dev/null
        rm -f "$_tl/$META_DIR/${svname}.desc"
        info "Deleted snapshot: $snap_name"
        return
    fi

    # destroy BE
    local bename="${BE_PREFIX}${name}"
    local bepath="$_tl/$bename"

    [[ -d "$bepath" ]] || die "'$name' not found"

    local sid did
    sid=$(subvol_id_of "$bepath")
    did=$(default_id)
    [[ "$sid" != "$did" ]] || die "cannot delete the active boot environment"

    if ! $no_confirm; then
        read -rp "Delete boot environment '$name'? [y/N] " yn
        [[ "$yn" =~ ^[Yy]$ ]] || return 0
    fi

    # Check if mounted (find actual mountpoint)
    local mounted_at
    mounted_at=$(_find_mountpoint "$bename") || true

    if [[ -n "$mounted_at" ]]; then
        if $force_umount; then
            warn "Force unmounting '$name' ($mounted_at)..."
            umount -l "$mounted_at" 2>/dev/null || true
        else
            die "'$name' is mounted at $mounted_at. Use -f to force unmount."
        fi
    fi

    btrfs subvolume delete "$bepath" >/dev/null
    rm -f "$_tl/$META_DIR/${bename}.desc"
    info "Deleted: $name"
}

# beadm list [-a | -ds] [-H] [name]
cmd_list() {
    need_btrfs
    mount_toplevel

    local show_all=false show_datasets=false show_snaps=false
    local machine=false
    local OPTIND=1

    while getopts ":adsH" opt; do
        case "$opt" in
            a) show_all=true ;;
            d) show_datasets=true ;;
            s) show_snaps=true ;;
            H) machine=true ;;
            *) die "unknown option: -$OPTARG" ;;
        esac
    done
    shift $((OPTIND - 1))

    local filter="${1:-}"
    local did crp
    did=$(default_id)
    crp=$(current_root_path)

    if ! $machine; then
        printf "${_B}%-28s %-5s %-12s %-8s %-20s %s${_0}\n" \
            "BE" "Flags" "Mountpoint" "Space" "Created" "Description"
    fi

    _list_be_cb() {
        local id="$1" svname="$2"
        [[ "$svname" == ${BE_PREFIX}* ]] || return 0

        local short="${svname#${BE_PREFIX}}"
        [[ -z "$filter" || "$short" == "$filter" ]] || return 0

        # Flags: N=active now, R=active on reboot
        local flags="-"
        local is_now=false is_reboot=false
        [[ "$svname" == "$crp" ]] && is_now=true
        [[ "$id" == "$did" ]] && is_reboot=true
        if $is_now && $is_reboot; then flags="NR"
        elif $is_now; then flags="N"
        elif $is_reboot; then flags="R"
        fi

        # Mountpoint — find by SOURCE (any mountpoint)
        local mnt="-"
        if $is_now; then
            mnt="/"
        else
            local found_mnt
            found_mnt=$(_find_mountpoint "$svname") || true
            [[ -n "$found_mnt" ]] && mnt="$found_mnt"
        fi

        # Space
        local space
        space=$(btrfs subvolume show "$_tl/$svname" 2>/dev/null \
            | awk '/Exclusive:/ {print $2 $3}') || space="?"
        [[ "$space" == "?" ]] && space="-"

        # Created
        local created
        created=$(btrfs subvolume show "$_tl/$svname" 2>/dev/null \
            | awk '/Creation time:/ {print $3, $4}') || created="?"

        # Description
        local desc
        desc=$(meta_get "$svname")

        if $machine; then
            printf '%s;%s;%s;%s;%s;%s\n' \
                "$short" "$flags" "$mnt" "$space" "$created" "$desc"
        else
            printf "%-28s %-5s %-12s %-8s %-20s %s\n" \
                "$short" "$flags" "$mnt" "$space" "$created" "$desc"
        fi
    }

    _iter_subvols "$_tl" _list_be_cb

    # Nested subvolumes (datasets) — show with -d or -a
    if $show_datasets || $show_all; then
        local root_path
        root_path=$(current_root_path)
        local has_nested=false

        _list_datasets_cb() {
            local _id="$1" svname="$2"
            [[ "$svname" == "${root_path}/"* ]] || return 0
            if ! $has_nested; then
                has_nested=true
                if ! $machine; then
                    echo
                    printf "${_B}Nested subvolumes (shared):${_0}\n"
                fi
            fi
            local relative="${svname#${root_path}/}"
            if $machine; then
                printf 'dataset:%s;-;-;-;-;\n' "$relative"
            else
                printf "  %-26s (shared)\n" "$relative"
            fi
        }

        _iter_subvols "$_tl" _list_datasets_cb
    fi

    # Snapshots (@snap-*) — show with -s or -a
    if $show_snaps || $show_all; then
        if ! $machine; then
            echo
            printf "${_B}Snapshots:${_0}\n"
        fi

        _list_snaps_cb() {
            local _id="$1" svname="$2"
            [[ "$svname" == ${SNAP_PREFIX}* ]] || return 0
            local short="${svname#${SNAP_PREFIX}}"
            local created
            created=$(btrfs subvolume show "$_tl/$svname" 2>/dev/null \
                | awk '/Creation time:/ {print $3, $4}') || created="?"
            local desc
            desc=$(meta_get "$svname")
            if $machine; then
                printf '@%s;-;-;-;%s;%s\n' "$short" "$created" "$desc"
            else
                printf "  @%-25s %-20s %s\n" "$short" "$created" "$desc"
            fi
        }

        _iter_subvols "$_tl" _list_snaps_cb
    fi

    # snapper snapshots — show with -a
    if $show_all && [[ -d "$_tl/.snapshots" ]]; then
        if ! $machine; then
            echo
            printf "${_B}snapper:${_0}\n"
        fi
        for d in "$_tl/.snapshots"/*/; do
            [[ -d "${d}snapshot" ]] || continue
            local num="${d%/}"; num="${num##*/}"
            local sd=""
            [[ -f "${d}info.xml" ]] && \
                sd=$(grep -oP '<description>\K[^<]+' "${d}info.xml" 2>/dev/null || true)
            if $machine; then
                printf 'snapper#%s;-;-;-;-;%s\n' "$num" "$sd"
            else
                printf "  snapper#%-19s %s\n" "$num" "$sd"
            fi
        done
    fi

    # timeshift snapshots — show with -a
    if $show_all && [[ -d "$_tl/timeshift-btrfs/snapshots" ]]; then
        if ! $machine; then
            echo
            printf "${_B}timeshift:${_0}\n"
        fi
        for d in "$_tl/timeshift-btrfs/snapshots"/*/; do
            [[ -d "${d}@" ]] || continue
            local tn="${d%/}"; tn="${tn##*/}"
            if $machine; then
                printf 'timeshift/%s;-;-;-;-;\n' "$tn"
            else
                printf "  timeshift/%-17s\n" "$tn"
            fi
        done
    fi
}

# beadm activate name
cmd_activate() {
    need_root; need_btrfs; check_mount_opts; mount_toplevel

    local name="$1"
    local bename="${BE_PREFIX}${name}"
    local bepath="$_tl/$bename"

    [[ -d "$bepath" ]] || die "boot environment '$name' not found"

    local sid
    sid=$(subvol_id_of "$bepath")
    [[ -n "$sid" ]] || die "could not determine subvolid for '$name'"

    # Save previous default for rollback
    mkdir -p "$_tl/$META_DIR"
    default_id > "$_tl/$META_DIR/previous-default"

    btrfs subvolume set-default "$sid" "$_tl"
    info "Activated: $name (subvolid=$sid)"
    info "Reboot to apply."
}

# Interactive BE selection.
cmd_activate_interactive() {
    need_root; need_btrfs; check_mount_opts; mount_toplevel

    local did
    did=$(default_id)
    local chosen
    chosen=$(_choose_be "$_tl" "$did")
    cmd_activate "$chosen"
}

# beadm mount name mountpoint
cmd_mount() {
    need_root; need_btrfs; mount_toplevel

    local name="${1:?specify BE name}"
    local mnt="${2:?specify mountpoint}"
    local bename="${BE_PREFIX}${name}"

    [[ -d "$_tl/$bename" ]] || die "boot environment '$name' not found"
    [[ -d "$mnt" ]] || die "'$mnt' does not exist"
    mountpoint -q "$mnt" && die "'$mnt' is already mounted"

    local dev
    dev=$(root_dev)
    mount -o "subvol=${bename}" "$dev" "$mnt"
    info "Mounted: $name -> $mnt"
}

# beadm unmount [-f] name
cmd_unmount() {
    need_root

    local force=false
    local OPTIND=1

    while getopts ":f" opt; do
        case "$opt" in
            f) force=true ;;
            *) die "unknown option: -$OPTARG" ;;
        esac
    done
    shift $((OPTIND - 1))

    local name="${1:?specify BE name}"
    local bename="${BE_PREFIX}${name}"

    # Find mountpoint by subvol name in SOURCE
    local mnt
    mnt=$(_find_mountpoint "$bename") || true

    if [[ -z "$mnt" ]]; then
        die "'$name' is not mounted"
    fi

    if $force; then
        umount -l "$mnt" 2>/dev/null || die "failed to unmount '$mnt'"
    else
        umount "$mnt" 2>/dev/null || die "failed to unmount '$mnt' (use -f to force)"
    fi
    info "Unmounted: $name"
}

# beadm rename old new
cmd_rename() {
    need_root; need_btrfs; mount_toplevel

    local old="${1:?specify current BE name}"
    local new="${2:?specify new BE name}"

    local old_bename="${BE_PREFIX}${old}"
    local new_bename="${BE_PREFIX}${new}"

    [[ -d "$_tl/$old_bename" ]] || die "boot environment '$old' not found"
    [[ ! -d "$_tl/$new_bename" ]] || die "boot environment '$new' already exists"

    mv "$_tl/$old_bename" "$_tl/$new_bename"

    # Move metadata
    [[ -f "$_tl/$META_DIR/${old_bename}.desc" ]] && \
        mv "$_tl/$META_DIR/${old_bename}.desc" "$_tl/$META_DIR/${new_bename}.desc"

    info "Renamed: $old -> $new"
}

# --- Compatibility: snapshot and clone ---

# snapshot [name] [description]
cmd_snapshot() {
    need_root; need_btrfs; mount_toplevel

    local name="${1:-$(timestamp)}"
    local desc="${2:-manual snapshot}"
    local svname="${SNAP_PREFIX}${name}"

    _make_snapshot "$(_current_root_dir)" "$svname" "$desc"
    info "Snapshot created: $name"
}

# clone <source> [name] [description]
cmd_clone() {
    need_root; need_btrfs; mount_toplevel

    local source="${1:?specify source}"
    local name="${2:-$(timestamp)}"
    local desc="${3:-clone of $source}"
    local bename="${BE_PREFIX}${name}"

    local sp
    sp=$(_resolve_source "$source") || die "source '$source' not found"

    _make_clone "$sp" "$bename" "$desc"
    info "Boot environment created: $name"
}

# --- Extensions ---

cmd_check() {
    local ok=true

    local fstype
    fstype=$(findmnt -n -o FSTYPE /)
    if [[ "$fstype" == "btrfs" ]]; then
        printf "  root filesystem: ${_G}btrfs${_0}\n"
    else
        printf "  root filesystem: ${_R}%s${_0}\n" "$fstype"
        ok=false
    fi

    local fstab_opts
    fstab_opts=$(findmnt -n -o OPTIONS --fstab / 2>/dev/null) || fstab_opts=""
    if [[ "$fstab_opts" =~ subvol=([^,]+) ]] && [[ "${BASH_REMATCH[1]}" != "/" ]]; then
        printf "  fstab: ${_R}subvol=%s${_0} — must be removed\n" "${BASH_REMATCH[1]}"
        ok=false
    elif [[ "$fstab_opts" =~ subvolid=([0-9]+) ]] && [[ "${BASH_REMATCH[1]}" != "0" && "${BASH_REMATCH[1]}" != "5" ]]; then
        printf "  fstab: ${_R}subvolid=%s${_0} — must be removed\n" "${BASH_REMATCH[1]}"
        ok=false
    else
        printf "  fstab: ${_G}default subvolume${_0}\n"
    fi

    if command -v btrfs &>/dev/null; then
        printf "  btrfs-progs:  ${_G}%s${_0}\n" "$(btrfs --version 2>&1 | awk '{print $2}')"
    else
        printf "  btrfs-progs:  ${_R}not found${_0}\n"
        ok=false
    fi

    $ok || { echo; die "system is not ready"; }
    printf "\n${_G}System is ready.${_0}\n"
}

cmd_status() {
    need_btrfs
    local did crp
    did=$(default_id)
    crp=$(current_root_path)
    info "Current root: ${crp:-<toplevel>}"
    info "Default subvolume: $(btrfs subvolume list / \
        | awk -v id="$did" '$2==id {print $NF}')"
}

# shell <name> — chroot into BE (mount + chroot + unmount)
cmd_shell() {
    need_root; need_btrfs; mount_toplevel

    local name="$1"
    local bename="${BE_PREFIX}${name}"
    [[ -d "$_tl/$bename" ]] || die "boot environment '$name' not found"

    _shell_inner() {
        local mnt="$1"
        info "Entering '$name'. Type 'exit' to leave."
        chroot "$mnt" /bin/bash || true
        info "Leaving '$name'."
    }

    _with_mounted_be "$bename" _shell_inner
}

# upgrade [-d desc] [name]
cmd_upgrade() {
    need_root; need_btrfs; check_mount_opts; mount_toplevel

    local desc=""
    local OPTIND=1

    while getopts ":d:" opt; do
        case "$opt" in
            d) desc="$OPTARG" ;;
            :) die "option -$OPTARG requires an argument" ;;
            *) die "unknown option: -$OPTARG" ;;
        esac
    done
    shift $((OPTIND - 1))

    local name="${1:-upgrade-$(timestamp)}"
    local bename="${BE_PREFIX}${name}"
    [[ -z "$desc" ]] && desc="upgrade $(date -u +%Y-%m-%d)"

    # 1. Snapshot current system (safety net)
    info "Snapshotting current system..."
    cmd_snapshot "pre-${name}" "before upgrade"

    # 2. Clone current root filesystem
    _make_clone "$(_current_root_dir)" "$bename" "$desc"
    info "Clone created: $name"

    # 3. Upgrade in chroot with guaranteed cleanup
    _upgrade_inner() {
        local mnt="$1"
        info "Starting upgrade..."
        chroot "$mnt" sh -c 'apt-get update && apt-get -y dist-upgrade'
    }

    if _with_mounted_be "$bename" _upgrade_inner; then
        info "Upgrade completed successfully."
        cmd_activate "$name"
    else
        warn "Upgrade failed. BE not activated."
        read -rp "Delete failed clone? [y/N] " yn
        [[ "$yn" =~ ^[Yy]$ ]] && cmd_destroy -F "$name"
        return 1
    fi
}

# Convert min_age (7d, 4w, 2m, 24h) to seconds.
_age_to_seconds() {
    local spec="$1"
    [[ "$spec" == "0" ]] && echo 0 && return
    local num="${spec%[hdwm]}"
    local unit="${spec##*[0-9]}"
    case "$unit" in
        h) echo $(( num * 3600 )) ;;
        d) echo $(( num * 86400 )) ;;
        w) echo $(( num * 604800 )) ;;
        m) echo $(( num * 2592000 )) ;;  # 30 days
        *) die "unknown age suffix: '$unit' (in '$spec')" ;;
    esac
}

# Get creation time of a subvolume in epoch seconds.
_subvol_ctime() {
    local path="$1"
    local ctime
    ctime=$(btrfs subvolume show "$path" 2>/dev/null \
        | awk '/Creation time:/ {print $3, $4}') || return 1
    date -d "$ctime" +%s 2>/dev/null || return 1
}

# prune — cleanup by PRUNE_RULES.
# No arguments: apply all rules from config.
# With argument N: legacy mode — keep N newest BEs.
cmd_prune() {
    need_root; mount_toplevel

    # Legacy mode: prune N
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
        _prune_legacy "$1"
        return
    fi

    local did
    did=$(default_id)
    local now
    now=$(date +%s)
    local deleted=0

    # Collect all subvolumes (sorted by generation, oldest first)
    local -a all_svnames=() all_ids=()

    # Cannot use _iter_subvols here — callback runs in same shell but
    # arrays modified inside process substitution loops are lost.
    while IFS= read -r line; do
        local id svname
        id=$(awk '{print $2}' <<< "$line")
        svname=$(awk '{print $NF}' <<< "$line")
        all_svnames+=("$svname")
        all_ids+=("$id")
    done < <(btrfs subvolume list "$_tl" --sort=gen 2>/dev/null \
             || btrfs subvolume list "$_tl")

    # Set of already processed subvolumes (first matching rule wins)
    local -A processed=()

    for rule in "${PRUNE_RULES[@]}"; do
        local pattern min_keep min_age_spec
        IFS=: read -r pattern min_keep min_age_spec <<< "$rule"

        local min_age_sec
        min_age_sec=$(_age_to_seconds "$min_age_spec")

        # Collect candidates for this rule
        local -a candidates=()
        for (( i=0; i<${#all_svnames[@]}; i++ )); do
            local sv="${all_svnames[$i]}"
            local sid="${all_ids[$i]}"

            # Already processed by another rule
            [[ -z "${processed[$sv]:-}" ]] || continue

            # Glob match
            # shellcheck disable=SC2254
            case "$sv" in $pattern) ;; *) continue ;; esac

            # Never delete the active BE
            [[ "$sid" != "$did" ]] || continue

            processed[$sv]=1
            candidates+=("$sv")
        done

        local total=${#candidates[@]}
        (( total > min_keep )) || continue

        local to_delete=$(( total - min_keep ))
        local rule_deleted=0

        # Delete from the beginning (oldest first, by generation)
        for sv in "${candidates[@]}"; do
            (( rule_deleted < to_delete )) || break

            # Check min_age
            if (( min_age_sec > 0 )); then
                local ctime
                ctime=$(_subvol_ctime "$_tl/$sv") || continue
                local age=$(( now - ctime ))
                (( age >= min_age_sec )) || continue
            fi

            btrfs subvolume delete "$_tl/$sv" >/dev/null
            rm -f "$_tl/$META_DIR/${sv}.desc"
            info "  deleted: $sv"
            (( rule_deleted++ )) || true
            (( deleted++ )) || true
        done
    done

    if (( deleted == 0 )); then
        info "Nothing to delete."
    else
        info "Deleted: $deleted item(s)."
    fi
}

# Legacy: prune N — keep N newest BEs (@be-*).
_prune_legacy() {
    local keep="$1"
    local did
    did=$(default_id)

    local -a candidates=()
    while IFS= read -r line; do
        local svname id
        svname=$(awk '{print $NF}' <<< "$line")
        id=$(awk '{print $2}' <<< "$line")
        [[ "$svname" == ${BE_PREFIX}* ]] || continue
        [[ "$id" != "$did" ]] || continue
        candidates+=("$svname")
    done < <(btrfs subvolume list "$_tl" --sort=gen 2>/dev/null \
             || btrfs subvolume list "$_tl")

    local total=${#candidates[@]}
    if (( total <= keep )); then
        info "Nothing to delete ($total item(s), limit $keep)."
        return
    fi

    local n=$((total - keep))
    info "Deleting $n old BE(s) (keeping $keep)..."
    for (( i=0; i<n; i++ )); do
        local sv="${candidates[$i]}"
        btrfs subvolume delete "$_tl/$sv" >/dev/null
        rm -f "$_tl/$META_DIR/${sv}.desc"
        info "  deleted: ${sv#${BE_PREFIX}}"
    done
}

# rescue <mountpoint>
cmd_rescue() {
    local mnt="${1:?specify btrfs volume mountpoint}"
    mountpoint -q "$mnt" || die "'$mnt' is not a mountpoint"
    [[ "$(findmnt -n -o FSTYPE "$mnt")" == "btrfs" ]] || die "'$mnt' is not btrfs"

    local chosen
    chosen=$(_choose_be "$mnt")

    # Find subvolid for chosen BE
    local bename="${BE_PREFIX}${chosen}"
    local sid
    sid=$(btrfs subvolume show "$mnt/$bename" 2>/dev/null \
        | awk '/Subvolume ID:/ {print $3}')
    [[ -n "$sid" ]] || die "could not determine subvolid for '$chosen'"

    btrfs subvolume set-default "$sid" "$mnt"
    info "Activated: $chosen (subvolid=$sid)"
    info "Reboot from primary media."
}

# --- APT hook ---

cmd_apt_hook_install() {
    need_root
    cat > /etc/apt/apt.conf.d/80-be-snapshot << 'HOOK'
DPkg::Pre-Invoke { "/usr/local/sbin/be-btrfs apt-pre-hook 2>/dev/null || true"; };
HOOK
    info "APT hook installed."
}

cmd_apt_pre_hook() {
    need_btrfs
    mount_toplevel
    local name="apt-$(timestamp)"
    local desc
    desc="apt: $(tr '\0' ' ' < /proc/$PPID/cmdline 2>/dev/null | head -c 200 || echo '?')"
    cmd_snapshot "$name" "$desc" 2>/dev/null || true
}

# --- Entry point ---

usage() {
    cat <<EOF
${PROG} v${VERSION} — Boot Environment Manager for btrfs

Usage: ${PROG} <command> [options] [arguments]

Commands:
  create [-a] [-d desc] [-e source] name
                                Create BE (clone of current or specified source)
  create name@snapshot          Create a snapshot of a BE
  destroy [-fF] name            Delete BE (-f: force unmount, -F: no confirmation)
  destroy [-F] name@snapshot    Delete snapshot
  list [-a|-ds] [-H] [name]     List BEs (-H: machine-parseable)
  mount name mountpoint         Mount a BE
  unmount [-f] name             Unmount a BE
  rename old new                Rename a BE
  activate [name]               Activate BE (no name = interactive)

Additional commands:
  snapshot [name] [description] Snapshot current system (read-only)
  clone <source> [name]         Clone from external snapshot (writable BE)
  shell <name>                  Chroot into BE (mount + shell + unmount)
  upgrade [-d desc] [name]      Clone + apt dist-upgrade + activate
  prune                         Cleanup by rules from config
  prune N                       Keep N newest BEs (legacy)
  rescue <mountpoint>           Activate BE from rescue media
  check                         Check system compatibility
  status                        Current state

  apt-hook-install              Install APT hook

Sources for clone / create -e:
  <name>                        own snapshot (@snap-name) or BE
  snapper#<N>                   snapper snapshot
  timeshift/<date>              timeshift snapshot
EOF
}

main() {
    _load_config

    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        create)             cmd_create "$@" ;;
        destroy|rm)         cmd_destroy "$@" ;;
        list|ls)            cmd_list "$@" ;;
        activate)           if [[ $# -ge 1 ]]; then cmd_activate "$1"
                            else cmd_activate_interactive; fi ;;
        mount)              cmd_mount "$@" ;;
        unmount|umount)     cmd_unmount "$@" ;;
        rename)             cmd_rename "$@" ;;
        snapshot|snap)      cmd_snapshot "${1:-}" "${2:-}" ;;
        clone)              cmd_clone "$@" ;;
        shell|sh)           cmd_shell "${1:?specify BE name}" ;;
        upgrade)            cmd_upgrade "$@" ;;
        prune)              cmd_prune "${1:-}" ;;
        rescue)             cmd_rescue "${1:?specify mountpoint}" ;;
        check)              cmd_check ;;
        status)             cmd_status ;;
        apt-hook-install)   cmd_apt_hook_install ;;
        apt-pre-hook)       cmd_apt_pre_hook ;;
        help|-h|--help)     usage ;;
        version|-V|--version) echo "${PROG} v${VERSION}" ;;
        *)                  die "unknown command: $cmd" ;;
    esac
}

main "$@"
