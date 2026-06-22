#!/bin/sh
# =============================================================================
# untracked-audit.sh — Find files not owned by any package manager
# =============================================================================
# Scans system paths for files that dpkg/apt doesn't know about — manually
# installed binaries, compiled-from-source tools, pip/npm installs, dropped
# scripts, etc. These are the things a clean reinstall won't restore.
#
# Usage:
#   sudo sh untracked-audit.sh [OPTIONS]
#
# Options:
#   -p PATHS  Colon-separated paths to scan (default: /usr:/opt:/srv:/var/www:/var/lib:/usr/local)
#   -x PATHS  Colon-separated paths to exclude (default: /var/lib/docker:/var/lib/lxc:/var/lib/libvirt)
#   -o PATH   Output directory for archive (default: /root)
#   -t TYPES  File types to scan: f=files, l=symlinks, d=dirs (default: f)
#   --help    Show this help
#
# Output:
#   /root/untracked-audit-HOSTNAME-YYYYMMDD-HHMMSS.tar.gz
# =============================================================================

set -eu

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
SCAN_PATHS="/usr:/opt:/srv:/var/www:/var/lib:/usr/local"
EXCL_PATHS="/var/lib/docker:/var/lib/lxc:/var/lib/libvirt:/var/lib/mysql:/var/lib/postgresql"
OUT_DIR="/root"
FILE_TYPES="f"
HOSTNAME_VAL="$(hostname -s 2>/dev/null || echo unknown)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_NAME="untracked-audit-${HOSTNAME_VAL}-${TIMESTAMP}"
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
        -p) SCAN_PATHS="$2"; shift 2 ;;
        -x) EXCL_PATHS="$2"; shift 2 ;;
        -o) OUT_DIR="$2"; shift 2 ;;
        -t) FILE_TYPES="$2"; shift 2 ;;
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

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: this script must be run as root (use sudo)" >&2
        exit 1
    fi
}

require_dpkg() {
    if ! command -v dpkg >/dev/null 2>&1; then
        echo "Error: dpkg not found — this script requires a Debian/Ubuntu system" >&2
        exit 1
    fi
}

# Convert a colon-separated list to a series of -path exclusion args for find
# e.g. "/var/lib/docker:/var/lib/lxc" -> "-path /var/lib/docker -prune -o -path /var/lib/lxc -prune -o"
build_exclusions() {
    _result=""
    echo "$1" | tr ':' '\n' | while read -r _excl; do
        [ -z "$_excl" ] && continue
        printf ' -path %s -prune -o' "$_excl"
    done
}

# Pretty-print file size
file_size() {
    _f="$1"
    if command -v stat >/dev/null 2>&1; then
        stat -c%s "$_f" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# -----------------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------------
require_root
require_dpkg

mkdir -p \
    "${WORK_DIR}/untracked" \
    "${WORK_DIR}/by-owner" \
    "${WORK_DIR}/suspicious"

log "Starting untracked file audit of ${HOSTNAME_VAL} at ${TIMESTAMP}"
log "Scan paths : ${SCAN_PATHS}"
log "Exclusions : ${EXCL_PATHS}"

# -----------------------------------------------------------------------------
# Build the find command
# -----------------------------------------------------------------------------
# Construct -prune exclusions
EXCL_ARGS=""
echo "$EXCL_PATHS" | tr ':' '\n' | while read -r excl; do
    [ -d "$excl" ] && EXCL_ARGS="${EXCL_ARGS} -path ${excl} -prune -o"
done

# Build type flags for find
TYPE_FLAG=""
echo "$FILE_TYPES" | sed 's/./& /g' | tr ' ' '\n' | grep -v '^$' | while read -r t; do
    if [ -z "$TYPE_FLAG" ]; then
        TYPE_FLAG="-type $t"
    else
        TYPE_FLAG="${TYPE_FLAG} -o -type $t"
    fi
done

# -----------------------------------------------------------------------------
# 1. Collect all files under scan paths
# -----------------------------------------------------------------------------
log "--- Collecting files to check ---"

ALL_FILES="${WORK_DIR}/all-files.txt"
> "$ALL_FILES"

echo "$SCAN_PATHS" | tr ':' '\n' | while read -r scanpath; do
    [ -z "$scanpath" ] && continue
    if [ ! -d "$scanpath" ]; then
        warn "Scan path does not exist, skipping: ${scanpath}"
        continue
    fi
    log "Scanning ${scanpath}..."

    # Build exclusion args inline for this invocation
    excl_str=""
    echo "$EXCL_PATHS" | tr ':' '\n' | while read -r excl; do
        [ -z "$excl" ] && continue
        if [ -d "$excl" ]; then
            excl_str="${excl_str} -path ${excl} -prune -o"
        fi
    done

    # Run find — exclude pruned paths, then match files
    # We use -xdev to stay on the same filesystem (avoids crossing into tmpfs, proc, etc.)
    eval find "$scanpath" -xdev \
        $(echo "$EXCL_PATHS" | tr ':' '\n' | while read -r e; do
            [ -d "$e" ] && printf ' -path %s -prune -o' "$e"
          done) \
        -type f -print 2>/dev/null >> "$ALL_FILES"
done

TOTAL_FILES="$(wc -l < "$ALL_FILES")"
log "Total files to check: ${TOTAL_FILES}"

# -----------------------------------------------------------------------------
# 2. Check each file against dpkg
# -----------------------------------------------------------------------------
log "--- Checking against dpkg (this will take a while for large filesystems) ---"
log "Progress will print every 1000 files..."

UNTRACKED="${WORK_DIR}/untracked/untracked-files.txt"
TRACKED="${WORK_DIR}/untracked/tracked-files.txt"
ERRORS="${WORK_DIR}/untracked/check-errors.txt"

> "$UNTRACKED"
> "$TRACKED"
> "$ERRORS"

n=0
while read -r filepath; do
    n=$((n + 1))
    [ $((n % 1000)) -eq 0 ] && log "  checked ${n}/${TOTAL_FILES}..."

    result="$(dpkg -S "$filepath" 2>&1)"
    if echo "$result" | grep -q ': '; then
        # Owned by a package — extract package name
        pkg="$(echo "$result" | head -1 | cut -d: -f1)"
        echo "$pkg	$filepath" >> "$TRACKED"
    elif echo "$result" | grep -q 'no path found'; then
        echo "$filepath" >> "$UNTRACKED"
    else
        # Unexpected output — log it
        echo "$filepath	$result" >> "$ERRORS"
    fi
done < "$ALL_FILES"

UNTRACKED_COUNT="$(wc -l < "$UNTRACKED")"
TRACKED_COUNT="$(wc -l < "$TRACKED")"

ok "Tracked by dpkg  : ${TRACKED_COUNT}"
warn "Untracked files  : ${UNTRACKED_COUNT}"
[ -s "$ERRORS" ] && warn "Check errors     : $(wc -l < "$ERRORS") (see untracked/check-errors.txt)"

# -----------------------------------------------------------------------------
# 3. Annotate untracked files with ownership and permissions
# -----------------------------------------------------------------------------
log "--- Annotating untracked files ---"

ANNOTATED="${WORK_DIR}/untracked/untracked-annotated.txt"
{
    printf '%-12s %-8s %-8s %-10s %-12s %s\n' \
        "USER" "UID" "GID" "PERMS" "SIZE" "PATH"
    printf '%0.s-' $(seq 1 80); echo

    while read -r filepath; do
        [ -f "$filepath" ] || continue
        # stat format: permissions user uid gid size
        stat -c "%A	%U	%u	%G	%g	%s	$filepath" "$filepath" 2>/dev/null \
            | awk -F'\t' '{
                printf "%-12s %-8s %-8s %-10s %-12s %s\n",
                    $2, $3, $4, $1, $6, $7
            }'
    done < "$UNTRACKED"
} > "$ANNOTATED"
ok "$ANNOTATED"

# -----------------------------------------------------------------------------
# 4. Group untracked files by owner
# -----------------------------------------------------------------------------
log "--- Grouping by owner ---"

# Get unique owners
awk 'NR>2 {print $1}' "$ANNOTATED" | sort -u | while read -r owner; do
    outfile="${WORK_DIR}/by-owner/${owner}.txt"
    {
        printf '# Untracked files owned by: %s\n' "$owner"
        printf '%-10s %-10s %-12s %s\n' "PERMS" "GID" "SIZE" "PATH"
        grep "^${owner} " "$ANNOTATED" | awk '{print $3, $4, $5, $6}'
    } > "$outfile"
    ok "  by-owner/${owner}.txt ($(grep -c "^${owner} " "$ANNOTATED" 2>/dev/null || echo 0) files)"
done

# -----------------------------------------------------------------------------
# 5. Flag suspicious files
# -----------------------------------------------------------------------------
log "--- Flagging suspicious files ---"

SUID="${WORK_DIR}/suspicious/suid-sgid.txt"
WORLD_WRITE="${WORK_DIR}/suspicious/world-writable.txt"
HIDDEN="${WORK_DIR}/suspicious/hidden-untracked.txt"
UNKNOWN_OWNER="${WORK_DIR}/suspicious/unknown-owner.txt"
EXECUTABLES="${WORK_DIR}/suspicious/executables.txt"

# SUID/SGID untracked files — these are worth knowing about
find $(echo "$SCAN_PATHS" | tr ':' ' ') \
    \( -perm -4000 -o -perm -2000 \) -type f \
    2>/dev/null | while read -r f; do
    dpkg -S "$f" >/dev/null 2>&1 || echo "$f"
done > "$SUID"
ok "$SUID ($(wc -l < "$SUID") found)"

# World-writable untracked files
find $(echo "$SCAN_PATHS" | tr ':' ' ') \
    -perm -0002 -type f \
    2>/dev/null | while read -r f; do
    dpkg -S "$f" >/dev/null 2>&1 || echo "$f"
done > "$WORLD_WRITE"
ok "$WORLD_WRITE ($(wc -l < "$WORLD_WRITE") found)"

# Hidden files/dirs in system paths (unusual outside /home)
grep '/\.' "$UNTRACKED" 2>/dev/null > "$HIDDEN" || true
ok "$HIDDEN ($(wc -l < "$HIDDEN") found)"

# Files owned by UIDs that have no corresponding username
awk 'NR>2 && $1 == $2 { print }' "$ANNOTATED" > "$UNKNOWN_OWNER" 2>/dev/null || true
ok "$UNKNOWN_OWNER ($(wc -l < "$UNKNOWN_OWNER") orphaned-owner files)"

# Untracked executables (most interesting for migration)
while read -r filepath; do
    [ -x "$filepath" ] && echo "$filepath"
done < "$UNTRACKED" > "$EXECUTABLES"
ok "$EXECUTABLES ($(wc -l < "$EXECUTABLES") untracked executables)"

# -----------------------------------------------------------------------------
# 6. Interesting path summaries
# -----------------------------------------------------------------------------
log "--- Path summaries ---"

SUMMARY="${WORK_DIR}/untracked/path-summary.txt"
{
    echo "# Untracked files grouped by top-level directory"
    echo ""
    awk '{print $NF}' "$UNTRACKED" \
        | sed 's|^\(/[^/]*/[^/]*\).*|\1|' \
        | sort | uniq -c | sort -rn \
        | awk '{printf "  %6d  %s\n", $1, $2}'
    echo ""
    echo "# Common untracked directories (where the files actually live)"
    echo ""
    awk '{print $NF}' "$UNTRACKED" \
        | xargs -I{} dirname {} 2>/dev/null \
        | sort | uniq -c | sort -rn | head -40 \
        | awk '{printf "  %6d  %s\n", $1, $2}'
} > "$SUMMARY"
ok "$SUMMARY"

# -----------------------------------------------------------------------------
# 7. Generate a migration todo list for untracked files
# -----------------------------------------------------------------------------
log "--- Generating migration todo ---"

TODO="${WORK_DIR}/UNTRACKED-MIGRATION-TODO.md"
{
    echo "# Untracked Files — Migration Todo"
    echo "Generated: $(date)"
    echo ""
    echo "These files exist on disk but are **not owned by any package**."
    echo "A clean reinstall will not restore them. Each one needs a deliberate decision:"
    echo ""
    echo "- **Copy** — rsync it to the new host"
    echo "- **Reinstall** — it came from pip/npm/cargo/source; reinstall it properly"
    echo "- **Skip** — it's stale/unused, don't carry it forward"
    echo ""

    echo "## Untracked Executables"
    echo "These are the highest priority — things that are actively run."
    echo ""
    echo "| Decision | Path | Owner | Notes |"
    echo "|----------|------|-------|-------|"
    while read -r filepath; do
        owner="$(stat -c '%U' "$filepath" 2>/dev/null || echo unknown)"
        printf "| [ ] copy/reinstall/skip | \`%s\` | %s | |\n" "$filepath" "$owner"
    done < "$EXECUTABLES"
    echo ""

    echo "## SUID/SGID Untracked Files"
    echo "Worth reviewing — these run with elevated privileges."
    echo ""
    echo "| Decision | Path | Notes |"
    echo "|----------|------|-------|"
    while read -r filepath; do
        perms="$(stat -c '%A' "$filepath" 2>/dev/null || echo unknown)"
        printf "| [ ] copy/reinstall/skip | \`%s\` | %s |\n" "$filepath" "$perms"
    done < "$SUID"
    echo ""

    echo "## Files with Unknown Owners (orphaned UIDs)"
    echo "These are owned by UIDs that have no matching user on this system."
    echo ""
    echo "| Decision | Path | UID | Notes |"
    echo "|----------|------|-----|-------|"
    awk 'NR>1 {printf "| [ ] | `%s` | %s | |\n", $NF, $2}' "$UNKNOWN_OWNER" 2>/dev/null || true
    echo ""

    echo "## All Untracked Files by Directory"
    echo ""
    cat "$SUMMARY"
    echo ""

    echo "## pip / npm / cargo — check these separately"
    echo ""
    echo "These package managers install outside dpkg's knowledge:"
    echo ""
    echo "\`\`\`"
    echo "# pip"
    pip3 list --format=columns 2>/dev/null || echo "pip3 not found"
    echo ""
    echo "# npm global"
    npm list -g --depth=0 2>/dev/null || echo "npm not found"
    echo ""
    echo "# cargo"
    cargo install --list 2>/dev/null || echo "cargo not found"
    echo "\`\`\`"
    echo ""

} > "$TODO"
ok "Migration todo: $TODO"

# Clean up the intermediate full file list
rm -f "$ALL_FILES"

# -----------------------------------------------------------------------------
# 8. Package archive
# -----------------------------------------------------------------------------
log "--- Packaging archive ---"
ARCHIVE="${OUT_DIR}/${ARCHIVE_NAME}.tar.gz"
tar -czf "$ARCHIVE" -C /tmp "$ARCHIVE_NAME"
rm -rf "$WORK_DIR"

ARCHIVE_SIZE="$(du -sh "$ARCHIVE" | cut -f1)"

echo ""
echo "============================================================"
ok "Untracked audit complete!"
echo "  Archive : ${ARCHIVE}"
echo "  Size    : ${ARCHIVE_SIZE}"
echo ""
echo "Contents overview:"
echo "  untracked/"
echo "    untracked-files.txt      raw list of untracked paths"
echo "    untracked-annotated.txt  with owner, perms, size"
echo "    path-summary.txt         file counts by directory"
echo "    tracked-files.txt        dpkg-owned files (for reference)"
echo "  by-owner/"
echo "    <username>.txt           untracked files grouped by owner"
echo "  suspicious/"
echo "    suid-sgid.txt            untracked SUID/SGID files"
echo "    world-writable.txt       untracked world-writable files"
echo "    hidden-untracked.txt     dotfiles in system paths"
echo "    unknown-owner.txt        files with orphaned UIDs"
echo "    executables.txt          untracked executable files"
echo "  UNTRACKED-MIGRATION-TODO.md   your decision list"
echo "============================================================"
