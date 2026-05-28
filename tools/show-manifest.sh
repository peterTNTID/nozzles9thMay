#!/usr/bin/env bash
# =============================================================================
# show-manifest.sh — Pretty-print the LFS↔IPFS hash manifest
# =============================================================================
#
# Displays the .ipfs/manifest.jsonl as a human-readable table, showing
# the relationship between LFS SHA-256 OIDs and IPFS CIDs.
#
# Usage:
#   ./tools/show-manifest.sh             # Full table
#   ./tools/show-manifest.sh --json      # Raw JSONL output
#   ./tools/show-manifest.sh --stats     # Summary statistics only
#
# Dependencies: jq
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/.ipfs/manifest.jsonl"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Format file size for display
# ---------------------------------------------------------------------------
human_size() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        printf "%6.1f GB" "$(echo "scale=1; $bytes / 1073741824" | bc)"
    elif [ "$bytes" -ge 1048576 ]; then
        printf "%6.1f MB" "$(echo "scale=1; $bytes / 1048576" | bc)"
    elif [ "$bytes" -ge 1024 ]; then
        printf "%6.1f KB" "$(echo "scale=1; $bytes / 1024" | bc)"
    else
        printf "%6d B " "$bytes"
    fi
}

# ---------------------------------------------------------------------------
# Show stats
# ---------------------------------------------------------------------------
show_stats() {
    local total_files total_size pinned_count unpinned_count

    total_files=$(wc -l < "$MANIFEST" | tr -d ' ')
    total_size=$(jq -s '[.[].size] | add // 0' "$MANIFEST")
    pinned_count=$(jq -s '[.[] | select(.pinata_id != null and .pinata_id != "null")] | length' "$MANIFEST")
    unpinned_count=$((total_files - pinned_count))

    echo ""
    echo -e "${BOLD}Manifest Statistics${NC}"
    echo "─────────────────────────────────────"
    echo -e "  Total files:     ${total_files}"
    echo -e "  Total size:      $(human_size "$total_size")"
    echo -e "  Pinned (Pinata): ${GREEN}${pinned_count}${NC}"
    echo -e "  Local IPFS only: ${unpinned_count}"
    echo ""

    # File type breakdown
    echo -e "${BOLD}By extension:${NC}"
    jq -r '.path | split(".") | last | ascii_downcase' "$MANIFEST" \
        | sort | uniq -c | sort -rn \
        | while read -r count ext; do
            printf "  %-10s %d files\n" ".${ext}" "$count"
        done

    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local mode="table"

    case "${1:-}" in
        --json)  mode="json" ;;
        --stats) mode="stats" ;;
        --help|-h)
            echo "Usage: $0 [--json | --stats]"
            echo ""
            echo "  (default)   Pretty-print manifest as a table"
            echo "  --json      Output raw JSONL"
            echo "  --stats     Show summary statistics"
            exit 0
            ;;
    esac

    if [ ! -f "$MANIFEST" ] || [ ! -s "$MANIFEST" ]; then
        echo -e "${YELLOW}⚠${NC} Manifest is empty or not found: ${MANIFEST}"
        echo "  Run ./tools/lfs-to-ipfs.sh --all to populate it."
        exit 1
    fi

    case "$mode" in
        json)
            cat "$MANIFEST"
            ;;
        stats)
            show_stats
            ;;
        table)
            echo ""
            echo -e "${BOLD}LFS ↔ IPFS Hash Manifest${NC}"
            echo ""

            # Header
            printf "${BOLD}%-45s │ %-18s │ %-18s │ %9s │ %-6s${NC}\n" \
                "File" "LFS OID (sha256)" "IPFS CID" "Size" "Pinata"
            printf "%.0s─" {1..105}
            echo ""

            # Rows
            while IFS= read -r line; do
                local path lfs_oid ipfs_cid size pinata_id
                path=$(echo "$line" | jq -r '.path')
                lfs_oid=$(echo "$line" | jq -r '.lfs_oid')
                ipfs_cid=$(echo "$line" | jq -r '.ipfs_cid')
                size=$(echo "$line" | jq -r '.size')
                pinata_id=$(echo "$line" | jq -r '.pinata_id // "null"')

                # Truncate for display
                local display_path display_oid display_cid
                display_path="${path}"
                [ ${#display_path} -gt 45 ] && display_path="…${display_path: -44}"

                display_oid="${lfs_oid#sha256:}"
                display_oid="${display_oid:0:18}"

                display_cid="${ipfs_cid:0:18}"

                local pin_icon
                if [ "$pinata_id" != "null" ] && [ -n "$pinata_id" ]; then
                    pin_icon="${GREEN}  ✓${NC}"
                else
                    pin_icon="${DIM}  —${NC}"
                fi

                printf "%-45s │ %s │ %s │ %s │" \
                    "$display_path" "$display_oid" "$display_cid" "$(human_size "$size")"
                echo -e "$pin_icon"

            done < "$MANIFEST"

            echo ""
            show_stats
            ;;
    esac
}

main "$@"
