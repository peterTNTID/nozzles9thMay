#!/usr/bin/env bash
# =============================================================================
# pinata-pin.sh — Pin IPFS content to Pinata for persistent availability
# =============================================================================
#
# Pins files from the manifest to Pinata's infrastructure so they remain
# available on IPFS even when your local node goes offline.
#
# Requires PINATA_JWT environment variable (or .env file).
#
# Usage:
#   ./tools/pinata-pin.sh --all                     # Pin everything
#   ./tools/pinata-pin.sh --new-only                # Pin only un-pinned entries
#   ./tools/pinata-pin.sh "path/to/file.wav"        # Pin a specific file
#   ./tools/pinata-pin.sh --by-cid bafybei...       # Pin by CID directly
#   ./tools/pinata-pin.sh --status                  # Check pinning status
#
# Environment:
#   PINATA_JWT — Required. Get from https://app.pinata.cloud/developers/api-keys
#
# Dependencies: jq, curl
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/.ipfs/manifest.jsonl"

# Source .env if it exists
[ -f "$REPO_ROOT/.env" ] && source "$REPO_ROOT/.env"

PINATA_API="https://api.pinata.cloud"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${BLUE}ℹ${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Check for Pinata JWT
# ---------------------------------------------------------------------------
require_jwt() {
    if [ -z "${PINATA_JWT:-}" ]; then
        echo ""
        error "PINATA_JWT not set."
        echo ""
        echo "  To use Pinata pinning:"
        echo "  1. Sign up at https://app.pinata.cloud"
        echo "  2. Create an API key at https://app.pinata.cloud/developers/api-keys"
        echo "  3. Export your JWT:"
        echo "       export PINATA_JWT=\"your-jwt-here\""
        echo "  4. Or add to .env:"
        echo "       echo 'PINATA_JWT=your-jwt-here' >> .env"
        echo ""
        echo "  See docs/PINATA-SETUP.md for detailed instructions."
        echo ""
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Format file size for display
# ---------------------------------------------------------------------------
human_size() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(echo "scale=1; $bytes / 1073741824" | bc) GB"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(echo "scale=1; $bytes / 1048576" | bc) MB"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(echo "scale=1; $bytes / 1024" | bc) KB"
    else
        echo "${bytes} B"
    fi
}

# ---------------------------------------------------------------------------
# Pin by hash (remote pin — cheaper, no upload needed)
# ---------------------------------------------------------------------------
pin_by_hash() {
    local cid="$1"
    local name="$2"

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "${PINATA_API}/pinning/pinByHash" \
        -H "Authorization: Bearer ${PINATA_JWT}" \
        -H "Content-Type: application/json" \
        -d "{\"hashToPin\":\"${cid}\",\"pinataMetadata\":{\"name\":\"${name}\"}}" \
        2>/dev/null)

    local http_code body
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ]; then
        local pin_id
        pin_id=$(echo "$body" | jq -r '.id // .IpfsHash // empty')
        echo "$pin_id"
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Pin by upload (direct upload — fallback)
# ---------------------------------------------------------------------------
pin_by_upload() {
    local filepath="$1"
    local name="$2"

    if [ ! -f "$filepath" ]; then
        return 1
    fi

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "${PINATA_API}/pinning/pinFileToIPFS" \
        -H "Authorization: Bearer ${PINATA_JWT}" \
        -F "file=@${filepath}" \
        -F "pinataMetadata={\"name\":\"${name}\"}" \
        2>/dev/null)

    local http_code body
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ]; then
        local pin_id
        pin_id=$(echo "$body" | jq -r '.IpfsHash // .id // empty')
        echo "$pin_id"
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Update manifest entry with pinata_id
# ---------------------------------------------------------------------------
update_manifest_pinata_id() {
    local cid="$1"
    local pinata_id="$2"

    local tmpfile
    tmpfile=$(mktemp)

    jq -c "if .ipfs_cid == \"${cid}\" then .pinata_id = \"${pinata_id}\" else . end" "$MANIFEST" > "$tmpfile"
    mv "$tmpfile" "$MANIFEST"
}

# ---------------------------------------------------------------------------
# Pin a single manifest entry
# ---------------------------------------------------------------------------
pin_entry() {
    local path="$1"
    local cid="$2"
    local size="$3"

    local basename
    basename=$(basename "$path")

    # Try pinByHash first
    local pin_id
    if pin_id=$(pin_by_hash "$cid" "$basename"); then
        if [ -n "$pin_id" ]; then
            update_manifest_pinata_id "$cid" "$pin_id"
            echo -e "  ${GREEN}📌${NC} ${path} ($(human_size "$size")) ${DIM}→ pinByHash${NC}"
            return 0
        fi
    fi

    # Fall back to upload
    local filepath="$REPO_ROOT/$path"
    if [ -f "$filepath" ]; then
        if pin_id=$(pin_by_upload "$filepath" "$basename"); then
            if [ -n "$pin_id" ]; then
                update_manifest_pinata_id "$cid" "$pin_id"
                echo -e "  ${GREEN}📌${NC} ${path} ($(human_size "$size")) ${DIM}→ uploaded${NC}"
                return 0
            fi
        fi
    fi

    echo -e "  ${RED}✗${NC}  ${path} — pinning failed"
    return 1
}

# ---------------------------------------------------------------------------
# Show pin status
# ---------------------------------------------------------------------------
show_status() {
    echo ""
    echo -e "${BOLD}Pinata Pin Status${NC}"
    echo "─────────────────────────────────────"

    local total pinned unpinned pinned_size unpinned_size
    total=$(wc -l < "$MANIFEST" | tr -d ' ')
    pinned=$(jq -s '[.[] | select(.pinata_id != null and .pinata_id != "null")] | length' "$MANIFEST")
    unpinned=$((total - pinned))
    pinned_size=$(jq -s '[.[] | select(.pinata_id != null and .pinata_id != "null") | .size] | add // 0' "$MANIFEST")
    unpinned_size=$(jq -s '[.[] | select(.pinata_id == null or .pinata_id == "null") | .size] | add // 0' "$MANIFEST")

    echo ""
    echo -e "  ${GREEN}Pinned:${NC}     ${pinned} files ($(human_size "$pinned_size"))"
    echo -e "  ${YELLOW}Not pinned:${NC} ${unpinned} files ($(human_size "$unpinned_size"))"
    echo -e "  Total:      ${total} files"
    echo ""

    if [ "$unpinned" -gt 0 ]; then
        echo -e "${BOLD}Un-pinned files:${NC}"
        jq -r 'select(.pinata_id == null or .pinata_id == "null") | "  • \(.path)"' "$MANIFEST"
        echo ""
        echo "  Pin them: ./tools/pinata-pin.sh --new-only"
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local mode="help"
    local target_path=""
    local target_cid=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --all)      mode="all"; shift ;;
            --new-only) mode="new-only"; shift ;;
            --status)   mode="status"; shift ;;
            --by-cid)   mode="by-cid"; target_cid="$2"; shift 2 ;;
            --help|-h)  mode="help"; shift ;;
            *)          mode="single"; target_path="$1"; shift ;;
        esac
    done

    case "$mode" in
        help)
            echo "Usage: $0 [--all | --new-only | --status | --by-cid <cid> | <path>]"
            echo ""
            echo "Options:"
            echo "  --all       Pin all manifest entries to Pinata"
            echo "  --new-only  Pin only entries without a pinata_id"
            echo "  --status    Show current pinning status"
            echo "  --by-cid    Pin a specific CID"
            echo "  <path>      Pin a specific file by repo path"
            echo ""
            echo "Requires PINATA_JWT environment variable."
            exit 0
            ;;
        status)
            if [ ! -f "$MANIFEST" ] || [ ! -s "$MANIFEST" ]; then
                warn "Manifest is empty. Run ./tools/lfs-to-ipfs.sh --all first."
                exit 1
            fi
            show_status
            exit 0
            ;;
    esac

    require_jwt

    if [ ! -f "$MANIFEST" ] || [ ! -s "$MANIFEST" ]; then
        error "Manifest not found or empty: ${MANIFEST}"
        echo "  Run ./tools/lfs-to-ipfs.sh --all first."
        exit 1
    fi

    echo ""
    echo -e "${BOLD}Pinata Pinning${NC}"
    echo "─────────────────────────────────────"

    local pinned=0
    local failed=0
    local skipped=0
    local total_size=0

    case "$mode" in
        by-cid)
            local name="manual-pin"
            if pin_id=$(pin_by_hash "$target_cid" "$name"); then
                success "Pinned CID: ${target_cid}"
            else
                error "Failed to pin CID: ${target_cid}"
            fi
            ;;

        single)
            local entry
            entry=$(jq -c "select(.path==\"${target_path}\")" "$MANIFEST" 2>/dev/null | head -1)
            if [ -z "$entry" ]; then
                error "File not in manifest: ${target_path}"
                exit 1
            fi

            local cid size
            cid=$(echo "$entry" | jq -r '.ipfs_cid')
            size=$(echo "$entry" | jq -r '.size')

            if pin_entry "$target_path" "$cid" "$size"; then
                pinned=1
                total_size=$size
            else
                failed=1
            fi
            ;;

        all|new-only)
            echo ""
            while IFS= read -r line; do
                local path cid size pinata_id
                path=$(echo "$line" | jq -r '.path')
                cid=$(echo "$line" | jq -r '.ipfs_cid')
                size=$(echo "$line" | jq -r '.size')
                pinata_id=$(echo "$line" | jq -r '.pinata_id // "null"')

                # Skip already-pinned in --new-only mode (and --all to avoid re-pinning)
                if [ "$pinata_id" != "null" ] && [ -n "$pinata_id" ]; then
                    skipped=$((skipped + 1))
                    continue
                fi

                if pin_entry "$path" "$cid" "$size"; then
                    pinned=$((pinned + 1))
                    total_size=$((total_size + size))
                else
                    failed=$((failed + 1))
                fi
            done < "$MANIFEST"
            ;;
    esac

    echo ""
    echo "─────────────────────────────────────"
    echo -e "${BOLD}Pinned:${NC}  ${pinned} files ($(human_size "$total_size"))"
    [ "$skipped" -gt 0 ] && echo -e "${DIM}Skipped: ${skipped} (already pinned)${NC}"
    [ "$failed" -gt 0 ]  && echo -e "${RED}Failed:  ${failed}${NC}"
    echo ""
}

main "$@"
