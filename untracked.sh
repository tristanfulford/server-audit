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
#   -p PATHS  Colon-separated paths to scan
#             (default: /usr/local:/opt:/srv:/var/www)
#   -x PATHS  Colon-separated paths to exclude
#             (default: /var/lib/docker:/var/lib/lxc:/var/lib/libvirt)
#   -o PATH   Output directory for archive (default: /root)
#   --help    Show this help
#
# Output:
#   /root/untracked-audit-HOSTNAME-YYYYMMDD-HHMMSS.tar.gz
#
# Notes:
#   /usr and /var/lib are intentionally NOT in the default scan paths —
#   they contain hundreds of thousands of dpkg-managed files and will make
#   the scan take a very long time. Add them with -p if you need them.
# =============================================================================

set -eu

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
SCAN_PATHS="/usr/local:/opt:/srv:/var/www"
EXCL_PATHS="/var/lib/docker:/var/lib/lxc:/var/lib/libvirt:/var/lib/mysql:/var/lib/postgresql"
OUT_DIR="/root"
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

# Check whether a path should be excluded.
# Returns 0 (true) if the path starts with any excluded prefix.
is_excluded() {
    _check="$1"
    echo "$EXCL_PATHS" | tr ':' '\n' | while read -r excl; do
        [ -z "$excl" ] && continue
        case "$_check" in
            "$excl"*) echo "yes"; break ;;
        esac
    done
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
    log "Collecting from ${scanpath}..."
    # -xdev: stay on same filesystem (don't cross into proc, tmpfs, etc.)
    # We handle exclusions manually in the dpkg loop rather than in find,
    # to avoid the eval/subshell variable problem entirely.
    find "$scanpath" -xdev -type f 2>/dev/null >> "$ALL_FILES"
done

# Filter out excluded paths (do it as a simple grep -v pass)
FILTERED_FILES="${WORK_DIR}/filtered-files.txt"
> "$FILTERED_FILES"

# Build a grep pattern from excluded paths
EXCL_PATTERN="$(echo "$EXCL_PATHS" | tr ':' '\n' | grep -v '^$' | sed 's|^|^|' | tr '\n' '|' | sed 's/|$//')"

if [ -n "$EXCL_PATTERN" ]; then
    grep -Ev "$EXCL_PATTERN" "$ALL_FILES" > "$FILTERED_FILES" 2>/dev/null || true
else
    cp "$ALL_FILES" "$FILTERED_FILES"
fi

TOTAL_FILES="$(wc -l < "$FILTERED_FILES")"
log "Files to check after exclusions: ${TOTAL_FILES}"

if [ "$TOTAL_FILES" -eq 0 ]; then
    warn "No files found to check. Verify your scan paths exist."
    exit 1
fi

# -----------------------------------------------------------------------------
# 2. Check each file against dpkg
# -----------------------------------------------------------------------------
log "--- Checking against dpkg ---"
log "This may take a while. Progress prints every 500 files."

UNTRACKED="${WORK_DIR}/untracked/untracked-files.txt"
TRACKED="${WORK_DIR}/untracked/tracked-count.txt"

> "$UNTRACKED"

n=0
tracked=0
while IFS= read -r filepath; do
    n=$((n + 1))
    [ $((n % 500)) -eq 0 ] && log "  checked ${n}/${TOTAL_FILES}..."

    # dpkg -S exits non-zero and prints "no path found" for untracked files
    if dpkg -S "$filepath" >/dev/null 2>&1; then
        tracked=$((tracked + 1))
    else
        echo "$filepath" >> "$UNTRACKED"
    fi
done < "$FILTERED_FILES"

UNTRACKED_COUNT="$(wc -l < "$UNTRACKED")"

echo "tracked=$tracked" > "$TRACKED"
echo "untracked=$UNTRACKED_COUNT" >> "$TRACKED"

ok "Tracked by dpkg  : ${tracked}"
warn "Untracked files  : ${UNTRACKED_COUNT}"

rm -f "$ALL_FILES" "$FILTERED_FILES"

if [ "$UNTRACKED_COUNT" -eq 0 ]; then
    log "Nothing untracked found. Archive will still be created."
fi

# -----------------------------------------------------------------------------
# 3. Annotate untracked files with ownership and permissions
# -----------------------------------------------------------------------------
log "--- Annotating untracked files ---"

ANNOTATED="${WORK_DIR}/untracked/untracked-annotated.txt"
{
    printf '%-12s %-6s %-6s %-11s %-12s %s\n' \
        "USER" "UID" "GID" "PERMS" "SIZE_B" "PATH"
    printf -- '%.0s-' $(seq 1 80); echo

    while IFS= read -r filepath; do
        [ -e "$filepath" ] || continue
        stat -c "%U	%u	%g	%A	%s	%n" "$filepath" 2>/dev/null \
            | awk -F'\t' '{
                printf "%-12s %-6s %-6s %-11s %-12s %s\n",
                    $1, $2, $3, $4, $5, $6
            }'
    done < "$UNTRACKED"
} > "$ANNOTATED"
ok "$ANNOTATED"

# -----------------------------------------------------------------------------
# 4. Group untracked files by owner
# -----------------------------------------------------------------------------
log "--- Grouping by owner ---"

# Get unique owners from annotated file (skip header lines)
awk 'NR>2 {print $1}' "$ANNOTATED" | sort -u | while IFS= read -r owner; do
    [ -z "$owner" ] && continue
    outfile="${WORK_DIR}/by-owner/${owner}.txt"
    {
        printf '# Untracked files owned by: %s\n\n' "$owner"
        printf '%-6s %-6s %-11s %-12s %s\n' "UID" "GID" "PERMS" "SIZE_B" "PATH"
        awk -v o="$owner" 'NR>2 && $1==o {print $2, $3, $4, $5, $6}' "$ANNOTATED"
    } > "$outfile"
    count="$(awk -v o="$owner" 'NR>2 && $1==o' "$ANNOTATED" | wc -l)"
    ok "  by-owner/${owner}.txt (${count} files)"
done

# -----------------------------------------------------------------------------
# 5. Flag suspicious / interesting files
# -----------------------------------------------------------------------------
log "--- Flagging suspicious files ---"

SUID="${WORK_DIR}/suspicious/suid-sgid.txt"
WORLD_WRITE="${WORK_DIR}/suspicious/world-writable.txt"
HIDDEN="${WORK_DIR}/suspicious/hidden-files.txt"
ORPHANED="${WORK_DIR}/suspicious/orphaned-owner.txt"
EXECUTABLES="${WORK_DIR}/suspicious/executables.txt"

# SUID/SGID — untracked files running with elevated privileges
> "$SUID"
while IFS= read -r filepath; do
    [ -u "$filepath" ] || [ -g "$filepath" ] && echo "$filepath" >> "$SUID" || true
done < "$UNTRACKED"
ok "  suid-sgid.txt       : $(wc -l < "$SUID") found"

# World-writable
> "$WORLD_WRITE"
while IFS= read -r filepath; do
    perms="$(stat -c '%a' "$filepath" 2>/dev/null || echo 0)"
    case "$perms" in
        *2|*3|*6|*7) echo "$filepath" >> "$WORLD_WRITE" ;;
    esac
done < "$UNTRACKED"
ok "  world-writable.txt  : $(wc -l < "$WORLD_WRITE") found"

# Hidden files in system paths (dotfiles outside /home are unusual)
grep '/\.' "$UNTRACKED" > "$HIDDEN" 2>/dev/null || true
ok "  hidden-files.txt    : $(wc -l < "$HIDDEN") found"

# Orphaned owner — UID in stat output matches numeric (no username resolved)
# stat prints the UID number as the username when no match exists
> "$ORPHANED"
while IFS= read -r filepath; do
    uname="$(stat -c '%U' "$filepath" 2>/dev/null || echo UNKNOWN)"
    uid="$(stat -c '%u' "$filepath" 2>/dev/null || echo 0)"
    # If username == uid number, it's orphaned
    if [ "$uname" = "$uid" ]; then
        echo "$uid	$filepath" >> "$ORPHANED"
    fi
done < "$UNTRACKED"
ok "  orphaned-owner.txt  : $(wc -l < "$ORPHANED") found"

# Executables — highest priority for migration
> "$EXECUTABLES"
while IFS= read -r filepath; do
    [ -x "$filepath" ] && echo "$filepath" >> "$EXECUTABLES" || true
done < "$UNTRACKED"
ok "  executables.txt     : $(wc -l < "$EXECUTABLES") found"

# -----------------------------------------------------------------------------
# 6. Path summary
# -----------------------------------------------------------------------------
log "--- Path summary ---"

SUMMARY="${WORK_DIR}/untracked/path-summary.txt"
{
    echo "# Untracked file count by top-two directory levels"
    echo ""
    sed 's|\(/[^/]*/[^/]*\).*|\1|' "$UNTRACKED" \
        | sort | uniq -c | sort -rn \
        | awk '{printf "  %6d  %s\n", $1, $2}'
    echo ""
    echo "# Directories with the most untracked files"
    echo ""
    while IFS= read -r f; do dirname "$f"; done < "$UNTRACKED" \
        | sort | uniq -c | sort -rn | head -30 \
        | awk '{printf "  %6d  %s\n", $1, $2}'
} > "$SUMMARY"
ok "$SUMMARY"

# -----------------------------------------------------------------------------
# 7. Check language package managers
# -----------------------------------------------------------------------------
log "--- Language package managers ---"

LANGPKG="${WORK_DIR}/untracked/language-packages.txt"
{
    echo "# Packages installed outside dpkg"
    echo "# These will need reinstalling on the new host"
    echo ""

    echo "## pip3"
    pip3 list --format=columns 2>/dev/null || echo "  pip3 not found"
    echo ""

    echo "## npm (global)"
    npm list -g --depth=0 2>/dev/null || echo "  npm not found"
    echo ""

    echo "## cargo"
    cargo install --list 2>/dev/null || echo "  cargo not found"
    echo ""

    echo "## gem (ruby)"
    gem list 2>/dev/null || echo "  gem not found"
    echo ""

    echo "## go install"
    # Go binaries land in ~/go/bin or /usr/local/go/bin
    find /root/go/bin /home/*/go/bin /usr/local/go/bin \
        -type f 2>/dev/null || echo "  no go binaries found"

} > "$LANGPKG"
ok "$LANGPKG"

# -----------------------------------------------------------------------------
# 8. Generate migration todo
# -----------------------------------------------------------------------------
log "--- Generating migration todo ---"

TODO="${WORK_DIR}/UNTRACKED-MIGRATION-TODO.md"
{
    echo "# Untracked Files — Migration Todo"
    echo "Generated: $(date)"
    echo "Host: ${HOSTNAME_VAL}"
    echo ""
    echo "These files exist on disk but are **not owned by any package**."
    echo "A clean reinstall will **not** restore them."
    echo ""
    echo "Decision for each file:"
    echo "- **copy** — rsync it directly to the new host"
    echo "- **reinstall** — came from pip/npm/cargo/source; reinstall cleanly"
    echo "- **skip** — stale or unused, don't carry it forward"
    echo ""

    echo "## Untracked Executables (highest priority)"
    echo ""
    if [ -s "$EXECUTABLES" ]; then
        echo "| Decision | Path | Owner | Notes |"
        echo "|----------|------|-------|-------|"
        while IFS= read -r filepath; do
            owner="$(stat -c '%U' "$filepath" 2>/dev/null || echo unknown)"
            printf "| [ ] | \`%s\` | %s | |\n" "$filepath" "$owner"
        done < "$EXECUTABLES"
    else
        echo "_None found._"
    fi
    echo ""

    echo "## SUID/SGID Untracked Files"
    echo ""
    if [ -s "$SUID" ]; then
        echo "| Decision | Path | Perms | Notes |"
        echo "|----------|------|-------|-------|"
        while IFS= read -r filepath; do
            perms="$(stat -c '%A' "$filepath" 2>/dev/null || echo unknown)"
            printf "| [ ] | \`%s\` | %s | |\n" "$filepath" "$perms"
        done < "$SUID"
    else
        echo "_None found._"
    fi
    echo ""

    echo "## Orphaned Owner (UID has no matching user)"
    echo ""
    if [ -s "$ORPHANED" ]; then
        echo "| Decision | UID | Path | Notes |"
        echo "|----------|-----|------|-------|"
        while IFS= read -r line; do
            uid="$(echo "$line" | cut -f1)"
            path="$(echo "$line" | cut -f2)"
            printf "| [ ] | %s | \`%s\` | |\n" "$uid" "$path"
        done < "$ORPHANED"
    else
        echo "_None found._"
    fi
    echo ""

    echo "## Path Summary"
    echo ""
    echo "\`\`\`"
    cat "$SUMMARY"
    echo "\`\`\`"
    echo ""

    echo "## Language Package Managers"
    echo ""
    echo "\`\`\`"
    cat "$LANGPKG"
    echo "\`\`\`"

} > "$TODO"
ok "Migration todo: $TODO"

# -----------------------------------------------------------------------------
# 9. Package archive
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
echo "Key files:"
echo "  UNTRACKED-MIGRATION-TODO.md"
echo "  untracked/untracked-annotated.txt"
echo "  untracked/path-summary.txt"
echo "  untracked/language-packages.txt"
echo "  by-owner/<username>.txt"
echo "  suspicious/executables.txt"
echo "  suspicious/suid-sgid.txt"
echo "  suspicious/orphaned-owner.txt"
echo "============================================================"
