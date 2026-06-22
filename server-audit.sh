#!/bin/sh
# =============================================================================
# server-audit.sh — Pre-migration system inventory script
# =============================================================================
# Produces a dated archive of everything you need to rebuild this server:
#   - Running/enabled services
#   - Docker containers, images, compose file locations
#   - KVM/libvirt VMs
#   - Installed packages
#   - Cron jobs and systemd timers
#   - Listening ports
#   - Storage, mounts, fstab
#   - Network configuration
#   - UID/GID audit of /mnt and home directories
#   - User and group registry
#   - Tailscale state
#   - SSH keys and known hosts
#   - /etc snapshot (via git if etckeeper present, otherwise tar)
#
# Usage:
#   sudo sh server-audit.sh [OPTIONS]
#
# Options:
#   -m PATH   Path to mounted drive to audit (default: /mnt)
#   -h PATH   Path to home directories (default: /home)
#   -o PATH   Output directory for archive (default: /root)
#   -s        Skip /etc tar snapshot (use if etckeeper is already managing /etc)
#   --help    Show this help
#
# Output:
#   /root/server-audit-HOSTNAME-YYYYMMDD-HHMMSS.tar.gz
# =============================================================================

set -eu

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
MNT_PATH="/mnt"
HOME_PATH="/home"
OUT_DIR="/root"
SKIP_ETC_TAR=0
HOSTNAME_VAL="$(hostname -s 2>/dev/null || echo unknown)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_NAME="server-audit-${HOSTNAME_VAL}-${TIMESTAMP}"
WORK_DIR="/tmp/${ARCHIVE_NAME}"

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
show_help() {
    sed -n '/^# Usage:/,/^# =\+$/p' "$0" | sed 's/^# \?//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -m) MNT_PATH="$2"; shift 2 ;;
        -h) HOME_PATH="$2"; shift 2 ;;
        -o) OUT_DIR="$2"; shift 2 ;;
        -s) SKIP_ETC_TAR=1; shift ;;
        --help) show_help ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
skip() { printf '\033[1;90m[-]\033[0m %s\n' "$*"; }

# Run a command, write stdout to $1, warn on failure rather than aborting
capture() {
    _out="$1"; shift
    if command -v "$1" >/dev/null 2>&1; then
        "$@" >"$_out" 2>/dev/null && ok "$_out" || warn "Command failed (partial output may exist): $*"
    else
        skip "Not available: $1 — skipping $*"
        echo "# Command not available: $*" >"$_out"
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: this script must be run as root (use sudo)" >&2
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------------
require_root
mkdir -p \
    "${WORK_DIR}/services" \
    "${WORK_DIR}/docker" \
    "${WORK_DIR}/vms" \
    "${WORK_DIR}/packages" \
    "${WORK_DIR}/scheduled" \
    "${WORK_DIR}/network" \
    "${WORK_DIR}/storage" \
    "${WORK_DIR}/users" \
    "${WORK_DIR}/uid-gid" \
    "${WORK_DIR}/secrets" \
    "${WORK_DIR}/misc"

log "Starting audit of ${HOSTNAME_VAL} at ${TIMESTAMP}"
log "Working directory: ${WORK_DIR}"

# -----------------------------------------------------------------------------
# 1. Systemd services
# -----------------------------------------------------------------------------
log "--- Systemd services ---"
capture "${WORK_DIR}/services/running.txt" \
    systemctl list-units --type=service --state=running --no-pager --plain

capture "${WORK_DIR}/services/enabled.txt" \
    systemctl list-unit-files --state=enabled --no-pager --plain

capture "${WORK_DIR}/services/failed.txt" \
    systemctl list-units --state=failed --no-pager --plain

# Dump unit files for any enabled non-standard services
# (i.e. not from the base systemd package — likely user-created or installed)
systemctl list-unit-files --state=enabled --plain --no-legend 2>/dev/null \
    | awk '{print $1}' \
    | while read -r unit; do
        unitfile="$(systemctl show -p FragmentPath "$unit" 2>/dev/null | cut -d= -f2)"
        if echo "$unitfile" | grep -qE '^/etc/systemd|^/opt|^/home|^/root|^/srv|^/usr/local'; then
            cp "$unitfile" "${WORK_DIR}/services/" 2>/dev/null && \
                ok "Copied custom unit: $unitfile"
        fi
    done

# -----------------------------------------------------------------------------
# 2. Docker
# -----------------------------------------------------------------------------
log "--- Docker ---"
if command -v docker >/dev/null 2>&1; then
    capture "${WORK_DIR}/docker/containers.txt"   docker ps -a --no-trunc
    capture "${WORK_DIR}/docker/images.txt"       docker images --no-trunc
    capture "${WORK_DIR}/docker/networks.txt"     docker network ls
    capture "${WORK_DIR}/docker/volumes.txt"      docker volume ls

    # Inspect all volumes for their mount points
    docker volume ls -q 2>/dev/null | while read -r vol; do
        docker volume inspect "$vol" 2>/dev/null
    done > "${WORK_DIR}/docker/volume-details.json"
    ok "${WORK_DIR}/docker/volume-details.json"

    # Find all compose files on the system
    log "Searching for compose files (this may take a moment)..."
    find / \( -name "docker-compose.yml" \
           -o -name "docker-compose.yaml" \
           -o -name "compose.yml" \
           -o -name "compose.yaml" \) \
        ! -path "*/proc/*" ! -path "*/sys/*" ! -path "*/.git/*" \
        2>/dev/null > "${WORK_DIR}/docker/compose-locations.txt"
    ok "${WORK_DIR}/docker/compose-locations.txt"

    # Copy each compose file into the archive, preserving directory structure
    mkdir -p "${WORK_DIR}/docker/compose-files"
    while read -r cfile; do
        # Flatten path: replace / with _ for filename
        dest="${WORK_DIR}/docker/compose-files/$(echo "$cfile" | tr '/' '_')"
        cp "$cfile" "$dest" 2>/dev/null && ok "Copied compose: $cfile"
    done < "${WORK_DIR}/docker/compose-locations.txt"

    # Also grab any .env files sitting next to compose files
    mkdir -p "${WORK_DIR}/docker/env-files"
    while read -r cfile; do
        envfile="$(dirname "$cfile")/.env"
        if [ -f "$envfile" ]; then
            dest="${WORK_DIR}/docker/env-files/$(echo "$envfile" | tr '/' '_')"
            cp "$envfile" "$dest" 2>/dev/null && ok "Copied .env: $envfile"
        fi
    done < "${WORK_DIR}/docker/compose-locations.txt"
else
    skip "docker not found — skipping Docker section"
    echo "# docker not installed or not in PATH" > "${WORK_DIR}/docker/not-available.txt"
fi

# -----------------------------------------------------------------------------
# 3. KVM / libvirt VMs
# -----------------------------------------------------------------------------
log "--- KVM / libvirt ---"
if command -v virsh >/dev/null 2>&1; then
    capture "${WORK_DIR}/vms/list.txt" virsh list --all

    mkdir -p "${WORK_DIR}/vms/xml"
    virsh list --all --name 2>/dev/null | grep -v '^$' | while read -r vm; do
        virsh dumpxml "$vm" > "${WORK_DIR}/vms/xml/${vm}.xml" 2>/dev/null && \
            ok "Dumped VM XML: $vm"
    done

    # Locate disk images referenced in VM XMLs
    grep -h 'source file=' "${WORK_DIR}/vms/xml/"*.xml 2>/dev/null \
        | sed "s/.*source file='//;s)'/>.*//" \
        | sort -u > "${WORK_DIR}/vms/disk-image-paths.txt"
    ok "${WORK_DIR}/vms/disk-image-paths.txt"
else
    skip "virsh not found — skipping KVM/libvirt section"
    echo "# virsh not installed" > "${WORK_DIR}/vms/not-available.txt"
fi

# -----------------------------------------------------------------------------
# 4. Installed packages
# -----------------------------------------------------------------------------
log "--- Packages ---"
if command -v dpkg >/dev/null 2>&1; then
    capture "${WORK_DIR}/packages/dpkg-selections.txt" dpkg --get-selections
    capture "${WORK_DIR}/packages/dpkg-list.txt"       dpkg -l
    # Manually installed only (not pulled in as deps) — requires aptitude or apt-mark
    if command -v apt-mark >/dev/null 2>&1; then
        capture "${WORK_DIR}/packages/manually-installed.txt" apt-mark showmanual
    fi
elif command -v rpm >/dev/null 2>&1; then
    capture "${WORK_DIR}/packages/rpm-list.txt" rpm -qa --queryformat '%{NAME} %{VERSION}-%{RELEASE}\n'
fi

# pip packages installed globally or under /usr/local
if command -v pip3 >/dev/null 2>&1; then
    capture "${WORK_DIR}/packages/pip3-global.txt" pip3 list --format=columns
fi

# npm global packages
if command -v npm >/dev/null 2>&1; then
    capture "${WORK_DIR}/packages/npm-global.txt" npm list -g --depth=0
fi

# -----------------------------------------------------------------------------
# 5. Scheduled tasks
# -----------------------------------------------------------------------------
log "--- Scheduled tasks ---"
capture "${WORK_DIR}/scheduled/timers.txt" systemctl list-timers --all --no-pager

# root crontab
crontab -l > "${WORK_DIR}/scheduled/crontab-root.txt" 2>/dev/null \
    && ok "${WORK_DIR}/scheduled/crontab-root.txt" \
    || { echo "# no root crontab"; skip "No root crontab"; }

# All user crontabs
mkdir -p "${WORK_DIR}/scheduled/crontabs"
ls /var/spool/cron/crontabs/ 2>/dev/null | while read -r u; do
    cp "/var/spool/cron/crontabs/$u" "${WORK_DIR}/scheduled/crontabs/${u}.crontab" 2>/dev/null && \
        ok "Copied crontab: $u"
done

# /etc/cron.d entries
if [ -d /etc/cron.d ]; then
    cp -r /etc/cron.d "${WORK_DIR}/scheduled/cron.d" 2>/dev/null
    ok "Copied /etc/cron.d"
fi

# -----------------------------------------------------------------------------
# 6. Network
# -----------------------------------------------------------------------------
log "--- Network ---"
capture "${WORK_DIR}/network/ip-addr.txt"      ip addr show
capture "${WORK_DIR}/network/ip-route.txt"     ip route show
capture "${WORK_DIR}/network/ip-rule.txt"      ip rule show
capture "${WORK_DIR}/network/ss-listening.txt" ss -tulpn
capture "${WORK_DIR}/network/iptables.txt"     iptables-save
capture "${WORK_DIR}/network/ip6tables.txt"    ip6tables-save

# Copy network config files that exist
for f in /etc/network/interfaces /etc/resolv.conf /etc/hosts /etc/hostname; do
    [ -f "$f" ] && cp "$f" "${WORK_DIR}/network/$(basename "$f")" && ok "Copied $f"
done

# NetworkManager connections
if [ -d /etc/NetworkManager/system-connections ]; then
    cp -r /etc/NetworkManager/system-connections "${WORK_DIR}/network/NM-connections" 2>/dev/null
    ok "Copied NetworkManager connections"
fi

# Tailscale
if command -v tailscale >/dev/null 2>&1; then
    capture "${WORK_DIR}/network/tailscale-status.txt"   tailscale status
    capture "${WORK_DIR}/network/tailscale-ip.txt"       tailscale ip
fi

# -----------------------------------------------------------------------------
# 7. Storage and mounts
# -----------------------------------------------------------------------------
log "--- Storage ---"
capture "${WORK_DIR}/storage/lsblk.txt"   lsblk -f -o NAME,FSTYPE,LABEL,UUID,SIZE,MOUNTPOINT
capture "${WORK_DIR}/storage/findmnt.txt" findmnt --real
capture "${WORK_DIR}/storage/df.txt"      df -h --exclude-type=tmpfs --exclude-type=devtmpfs

cp /etc/fstab "${WORK_DIR}/storage/fstab" 2>/dev/null && ok "Copied /etc/fstab"

# mdadm RAID config if present
[ -f /etc/mdadm/mdadm.conf ] && \
    cp /etc/mdadm/mdadm.conf "${WORK_DIR}/storage/mdadm.conf" && ok "Copied mdadm.conf"

# LVM
if command -v vgs >/dev/null 2>&1; then
    { vgs; echo; pvs; echo; lvs; } > "${WORK_DIR}/storage/lvm.txt" 2>/dev/null
    ok "${WORK_DIR}/storage/lvm.txt"
fi

# ZFS
if command -v zpool >/dev/null 2>&1; then
    { zpool list; echo; zfs list; } > "${WORK_DIR}/storage/zfs.txt" 2>/dev/null
    ok "${WORK_DIR}/storage/zfs.txt"
fi

# -----------------------------------------------------------------------------
# 8. Users and groups
# -----------------------------------------------------------------------------
log "--- Users and groups ---"
getent passwd > "${WORK_DIR}/users/passwd.txt"
getent group  > "${WORK_DIR}/users/group.txt"
getent shadow > "${WORK_DIR}/users/shadow.txt" 2>/dev/null || \
    warn "Could not read shadow (run as root?)"

# Summarise human and service accounts
awk -F: '$3 >= 1000 && $1 != "nobody" { print $1, $3, $4, $6, $7 }' \
    /etc/passwd > "${WORK_DIR}/users/human-accounts.txt"
awk -F: '$3 < 1000 && $3 > 0 { print $1, $3, $4, $6, $7 }' \
    /etc/passwd > "${WORK_DIR}/users/service-accounts.txt"
ok "${WORK_DIR}/users/human-accounts.txt"
ok "${WORK_DIR}/users/service-accounts.txt"

# Copy SSH known_hosts and authorized_keys for each user
mkdir -p "${WORK_DIR}/secrets/ssh"
getent passwd | awk -F: '$6 ~ /^\/(home|root)/ { print $6 }' | while read -r hdir; do
    uname="$(basename "$hdir")"
    [ -d "${hdir}/.ssh" ] || continue
    mkdir -p "${WORK_DIR}/secrets/ssh/${uname}"
    for f in authorized_keys known_hosts config; do
        src="${hdir}/.ssh/${f}"
        [ -f "$src" ] && cp "$src" "${WORK_DIR}/secrets/ssh/${uname}/${f}" && ok "Copied $src"
    done
done

# -----------------------------------------------------------------------------
# 9. UID/GID audit — /mnt and /home
# -----------------------------------------------------------------------------
log "--- UID/GID audit ---"

# Helper: scan a path and produce a report
uid_gid_scan() {
    _path="$1"
    _label="$2"
    _out="${WORK_DIR}/uid-gid/${_label}"
    mkdir -p "$_out"

    log "Scanning ${_path} for UID/GID ownership..."

    # All unique (uid, gid, username, groupname) combinations present on the path
    find "$_path" -printf "%U\t%G\t%u\t%g\n" 2>/dev/null \
        | sort -u \
        > "${_out}/uid-gid-pairs.txt"
    ok "${_out}/uid-gid-pairs.txt"

    # Flag orphaned entries — numeric uid/gid with no matching name on this system
    # (these show up as the same number in both the numeric and name fields)
    awk '
        $1 == $3 { print "ORPHAN_UID", $1, $3, "(uid has no matching user)" }
        $2 == $4 { print "ORPHAN_GID", $2, $4, "(gid has no matching group)" }
    ' "${_out}/uid-gid-pairs.txt" | sort -u > "${_out}/orphaned.txt"

    orphan_count="$(wc -l < "${_out}/orphaned.txt")"
    if [ "$orphan_count" -gt 0 ]; then
        warn "${_label}: ${orphan_count} orphaned UID/GID(s) found — see ${_out}/orphaned.txt"
    else
        ok "${_label}: no orphaned UIDs/GIDs"
    fi

    # Per-directory summary: top-level dirs and their dominant owner
    find "$_path" -maxdepth 2 -printf "%p\t%U\t%G\t%u\t%g\n" 2>/dev/null \
        | sort > "${_out}/top-level-ownership.txt"
    ok "${_out}/top-level-ownership.txt"

    # File count by owner (uid) — useful to see who "owns" the most files
    find "$_path" -printf "%u\n" 2>/dev/null \
        | sort | uniq -c | sort -rn \
        > "${_out}/file-count-by-user.txt"
    ok "${_out}/file-count-by-user.txt"

    # Find files with unusual permissions
    find "$_path" \( -perm -4000 -o -perm -2000 -o -perm -0002 \) \
        -printf "%M\t%U\t%G\t%p\n" 2>/dev/null \
        > "${_out}/unusual-permissions.txt"
    ok "${_out}/unusual-permissions.txt"
}

[ -d "$MNT_PATH" ]  && uid_gid_scan "$MNT_PATH"  "mnt"  || warn "${MNT_PATH} does not exist, skipping"
[ -d "$HOME_PATH" ] && uid_gid_scan "$HOME_PATH" "home" || warn "${HOME_PATH} does not exist, skipping"

# Produce a consolidated UID/GID registry based on current system + what was found on disk
{
    printf '%-12s %-6s %-6s %-30s %s\n' "NAME" "UID" "GID" "HOME" "SHELL"
    printf '%0.s-' $(seq 1 75); echo
    awk -F: '{ printf "%-12s %-6s %-6s %-30s %s\n", $1, $3, $4, $6, $7 }' /etc/passwd
} > "${WORK_DIR}/uid-gid/registry.txt"
ok "${WORK_DIR}/uid-gid/registry.txt"

# Produce a migration remapping template — fill in "new_uid" and "new_gid" columns
{
    printf '# UID/GID remapping plan — fill in NEW_UID and NEW_GID before migration\n'
    printf '# Then use: find /path -uid OLD_UID -exec chown NEW_UID {} \\;\n'
    printf '#\n'
    printf '%-20s %-10s %-10s %-10s %-10s\n' "NAME" "OLD_UID" "OLD_GID" "NEW_UID" "NEW_GID"
    printf '%0.s-' $(seq 1 65); echo
    awk -F: '$3 >= 100 { printf "%-20s %-10s %-10s %-10s %-10s\n", $1, $3, $4, "?", "?" }' \
        /etc/passwd
} > "${WORK_DIR}/uid-gid/remap-plan.txt"
ok "${WORK_DIR}/uid-gid/remap-plan.txt"

# -----------------------------------------------------------------------------
# 10. /etc snapshot
# -----------------------------------------------------------------------------
log "--- /etc snapshot ---"
if [ "$SKIP_ETC_TAR" -eq 1 ]; then
    skip "/etc tar snapshot skipped (-s flag set)"
elif command -v etckeeper >/dev/null 2>&1; then
    etckeeper commit "server-audit pre-migration snapshot ${TIMESTAMP}" 2>/dev/null || true
    ok "etckeeper commit done"
    # Still tar it so it travels with the archive
    tar -czf "${WORK_DIR}/misc/etc-snapshot.tar.gz" /etc 2>/dev/null
    ok "Tarballed /etc as backup"
else
    warn "etckeeper not installed — doing plain tar of /etc"
    tar -czf "${WORK_DIR}/misc/etc-snapshot.tar.gz" /etc 2>/dev/null
    ok "Tarballed /etc"
fi

# -----------------------------------------------------------------------------
# 11. Miscellaneous
# -----------------------------------------------------------------------------
log "--- Misc ---"

# Kernel and OS info
{
    uname -a
    echo
    cat /etc/os-release 2>/dev/null
} > "${WORK_DIR}/misc/system-info.txt"
ok "${WORK_DIR}/misc/system-info.txt"

# BIOS/hardware info
capture "${WORK_DIR}/misc/dmidecode.txt" dmidecode

# PCI devices (useful to confirm what NICs, storage controllers etc are present)
capture "${WORK_DIR}/misc/lspci.txt" lspci -v

# USB devices
capture "${WORK_DIR}/misc/lsusb.txt" lsusb

# Running processes snapshot
capture "${WORK_DIR}/misc/ps.txt" ps auxf

# Environment for root
printenv > "${WORK_DIR}/misc/root-env.txt" 2>/dev/null

# Locale and timezone
{
    locale
    echo
    timedatectl status 2>/dev/null || cat /etc/timezone 2>/dev/null
} > "${WORK_DIR}/misc/locale-timezone.txt"
ok "${WORK_DIR}/misc/locale-timezone.txt"

# /var/log listing (don't copy logs, just list what's there)
ls -lhR /var/log > "${WORK_DIR}/misc/var-log-listing.txt" 2>/dev/null
ok "${WORK_DIR}/misc/var-log-listing.txt"

# Anacron / at jobs
[ -d /var/spool/anacron ] && ls /var/spool/anacron > "${WORK_DIR}/scheduled/anacron.txt"
command -v atq >/dev/null 2>&1 && atq > "${WORK_DIR}/scheduled/at-jobs.txt"

# -----------------------------------------------------------------------------
# 12. Generate migration checklist
# -----------------------------------------------------------------------------
log "--- Generating migration checklist ---"

CHECKLIST="${WORK_DIR}/MIGRATION-CHECKLIST.md"

{
    echo "# Migration Checklist — ${HOSTNAME_VAL} → new host"
    echo "Generated: $(date)"
    echo ""
    echo "Tick off each item as you: audit it, recreate it on the new host, and verify it."
    echo ""
    echo "| # | Category | Item | Audited | Migrated | Verified | Notes |"
    echo "|---|----------|------|:-------:|:--------:|:--------:|-------|"

    n=1

    # Services
    if [ -s "${WORK_DIR}/services/running.txt" ]; then
        grep -v '^UNIT\|^$\|loaded' "${WORK_DIR}/services/running.txt" 2>/dev/null \
            | awk '{print $1}' \
            | grep '\.service$' \
            | while read -r svc; do
                printf "| %d | Systemd | %s | [ ] | [ ] | [ ] | |\n" "$n" "$svc"
                n=$((n+1))
            done
    fi

    # Docker containers
    if [ -s "${WORK_DIR}/docker/containers.txt" ]; then
        tail -n +2 "${WORK_DIR}/docker/containers.txt" 2>/dev/null \
            | awk '{print $NF}' \
            | while read -r cname; do
                printf "| %d | Docker | %s | [ ] | [ ] | [ ] | |\n" "$n" "$cname"
                n=$((n+1))
            done
    fi

    # VMs
    if [ -s "${WORK_DIR}/vms/list.txt" ]; then
        tail -n +3 "${WORK_DIR}/vms/list.txt" 2>/dev/null \
            | grep -v '^-\|^$' \
            | awk '{print $2}' \
            | while read -r vm; do
                printf "| %d | VM | %s | [ ] | [ ] | [ ] | |\n" "$n" "$vm"
                n=$((n+1))
            done
    fi

    # Mounts from fstab (non-system)
    grep -v '^#\|^$\|tmpfs\|proc\|sysfs\|devpts\|swap' /etc/fstab 2>/dev/null \
        | awk '{print $2}' \
        | while read -r mp; do
            printf "| %d | Storage | fstab mount: %s | [ ] | [ ] | [ ] | |\n" "$n" "$mp"
            n=$((n+1))
        done

    # Orphaned UIDs on /mnt
    if [ -s "${WORK_DIR}/uid-gid/mnt/orphaned.txt" ]; then
        grep ORPHAN_UID "${WORK_DIR}/uid-gid/mnt/orphaned.txt" 2>/dev/null \
            | awk '{print $2}' | sort -u \
            | while read -r uid; do
                printf "| %d | UID/GID | Orphan UID %s on %s | [ ] | [ ] | [ ] | Remap before copy |\n" \
                    "$n" "$uid" "$MNT_PATH"
                n=$((n+1))
            done
    fi

    # Orphaned UIDs on /home
    if [ -s "${WORK_DIR}/uid-gid/home/orphaned.txt" ]; then
        grep ORPHAN_UID "${WORK_DIR}/uid-gid/home/orphaned.txt" 2>/dev/null \
            | awk '{print $2}' | sort -u \
            | while read -r uid; do
                printf "| %d | UID/GID | Orphan UID %s on %s | [ ] | [ ] | [ ] | Remap before copy |\n" \
                    "$n" "$uid" "$HOME_PATH"
                n=$((n+1))
            done
    fi

    # Fixed checklist items that always apply
    cat <<'FIXED'
| - | UID/GID | Fill in uid-gid/remap-plan.txt | [ ] | [ ] | [ ] | Plan UIDs before creating users |
| - | Users | Recreate human accounts with explicit UIDs | [ ] | [ ] | [ ] | |
| - | Users | Recreate service accounts (plex, immich, etc.) | [ ] | [ ] | [ ] | |
| - | Users | Recreate shared groups (e.g. media) | [ ] | [ ] | [ ] | |
| - | SSH | Copy authorized_keys to new host | [ ] | [ ] | [ ] | secrets/ssh/ |
| - | SSH | Verify SSH host keys if needed | [ ] | [ ] | [ ] | |
| - | Network | Assign static IP / hostname | [ ] | [ ] | [ ] | |
| - | Network | Recreate firewall rules | [ ] | [ ] | [ ] | network/iptables.txt |
| - | Network | Re-join Tailscale | [ ] | [ ] | [ ] | |
| - | Storage | Verify fstab UUIDs match new drives | [ ] | [ ] | [ ] | storage/fstab |
| - | Storage | rsync data from old drive (read-only mount) | [ ] | [ ] | [ ] | |
| - | Storage | chown pass after rsync using remap-plan | [ ] | [ ] | [ ] | |
| - | Docker | Install Docker + Docker Compose | [ ] | [ ] | [ ] | |
| - | Docker | Place compose files on new host | [ ] | [ ] | [ ] | docker/compose-files/ |
| - | Docker | Restore named volumes (Restic or volume export) | [ ] | [ ] | [ ] | |
| - | Docker | Restore .env files | [ ] | [ ] | [ ] | docker/env-files/ |
| - | Secrets | Rotate any secrets that should not transfer | [ ] | [ ] | [ ] | |
| - | Verify | All services responding on expected ports | [ ] | [ ] | [ ] | network/ss-listening.txt |
| - | Verify | Old server kept offline / read-only until stable | [ ] | [ ] | [ ] | |
FIXED

} > "$CHECKLIST"

ok "Migration checklist: ${CHECKLIST}"

# -----------------------------------------------------------------------------
# 13. Package the archive
# -----------------------------------------------------------------------------
log "--- Packaging archive ---"
ARCHIVE="${OUT_DIR}/${ARCHIVE_NAME}.tar.gz"
tar -czf "$ARCHIVE" -C /tmp "$ARCHIVE_NAME"
rm -rf "$WORK_DIR"

ARCHIVE_SIZE="$(du -sh "$ARCHIVE" | cut -f1)"

echo ""
echo "============================================================"
ok "Audit complete!"
echo "  Archive : ${ARCHIVE}"
echo "  Size    : ${ARCHIVE_SIZE}"
echo ""
echo "Contents overview:"
echo "  services/          — systemd units"
echo "  docker/            — containers, images, compose files, .env files"
echo "  vms/               — libvirt XML dumps + disk paths"
echo "  packages/          — dpkg/apt selections"
echo "  scheduled/         — crontabs, systemd timers"
echo "  network/           — IP config, firewall, Tailscale"
echo "  storage/           — lsblk, fstab, mounts, LVM/ZFS"
echo "  users/             — passwd, group, per-user SSH keys"
echo "  uid-gid/           — ownership audit of ${MNT_PATH} and ${HOME_PATH}"
echo "    mnt/uid-gid-pairs.txt        unique UIDs/GIDs on ${MNT_PATH}"
echo "    mnt/orphaned.txt             UIDs/GIDs with no matching user/group"
echo "    home/uid-gid-pairs.txt       same for ${HOME_PATH}"
echo "    registry.txt                 full UID/GID registry"
echo "    remap-plan.txt               fill this in before migrating"
echo "  misc/              — hardware, OS info, /etc snapshot"
echo "  MIGRATION-CHECKLIST.md         your tick-off list"
echo "============================================================"
