#!/usr/bin/env bash
# =============================================================================
# sync-manifest.sh — Push the local IPFS manifest to the LFS server
# =============================================================================
#
# Converts .ipfs/manifest.jsonl to a JSON array and POSTs it to the LFS
# server's /ipfs/manifest endpoint. This enables the server's IPFS gateway
# to resolve CIDs to GCS objects.
#
# Usage:
#   ./tools/sync-manifest.sh                # Push manifest to LFS server
#   ./tools/sync-manifest.sh --check        # Check what the server has
#   ./tools/sync-manifest.sh --dry-run      # Show what would be sent
#
# Requires the same LFS write credentials configured for git lfs push.
#
# Dependencies: jq, curl
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/.ipfs/manifest.jsonl"

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
# Get LFS server URL from .lfsconfig
# ---------------------------------------------------------------------------
get_lfs_url() {
    local url
    url=$(git config -f "$REPO_ROOT/.lfsconfig" lfs.url 2>/dev/null || true)
    if [ -z "$url" ]; then
        url=$(git config lfs.url 2>/dev/null || true)
    fi
    echo "$url"
}

# ---------------------------------------------------------------------------
# Get LFS credentials from git credential store
# ---------------------------------------------------------------------------
get_credentials() {
    local lfs_url="$1"
    local host
    host=$(echo "$lfs_url" | sed 's|https\?://||' | cut -d/ -f1)

    # Method 1: Try git credential fill (respects local + global config)
    local cred_output
    cred_output=$(printf "protocol=https\nhost=%s\n\n" "$host" \
        | GIT_DIR="$REPO_ROOT/.git" git credential fill 2>/dev/null) || true

    local username password
    username=$(echo "$cred_output" | grep '^username=' | cut -d= -f2-)
    password=$(echo "$cred_output" | grep '^password=' | cut -d= -f2-)

    if [ -n "$password" ]; then
        echo "${username:-lfs}:${password}"
        return
    fi

    # Method 2: Parse ~/.git-credentials directly
    if [ -f "$HOME/.git-credentials" ]; then
        local line
        line=$(grep "$host" "$HOME/.git-credentials" 2>/dev/null | head -1)
        if [ -n "$line" ]; then
            # Format: https://user:pass@host
            username=$(echo "$line" | sed 's|https\?://\([^:]*\):.*|\1|')
            password=$(echo "$line" | sed 's|https\?://[^:]*:\([^@]*\)@.*|\1|')
            if [ -n "$password" ]; then
                echo "${username:-lfs}:${password}"
                return
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
# Convert JSONL manifest to JSON array
# ---------------------------------------------------------------------------
manifest_to_json() {
    jq -s '.' "$MANIFEST"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local mode="push"

    case "${1:-}" in
        --check)   mode="check" ;;
        --dry-run) mode="dry-run" ;;
        --help|-h)
            echo "Usage: $0 [--check | --dry-run]"
            echo ""
            echo "Push the local IPFS manifest to the LFS server's gateway."
            echo ""
            echo "  (default)    Push manifest to server"
            echo "  --check      Show the server's current manifest"
            echo "  --dry-run    Show what would be pushed"
            exit 0
            ;;
    esac

    # Check dependencies
    command -v jq &>/dev/null || { error "jq not installed"; exit 1; }

    # Get LFS server URL
    local lfs_url
    lfs_url=$(get_lfs_url)
    if [ -z "$lfs_url" ]; then
        error "Cannot find LFS server URL. Check .lfsconfig or git config lfs.url"
        exit 1
    fi

    echo ""
    echo -e "${BOLD}Manifest Sync → LFS Server${NC}"
    echo "─────────────────────────────────────"
    info "Server: ${lfs_url}"

    case "$mode" in
        check)
            echo ""
            info "Fetching server manifest..."
            local response
            response=$(curl -sf "${lfs_url}/ipfs/manifest" 2>/dev/null) || {
                error "Failed to reach ${lfs_url}/ipfs/manifest"
                echo "  The server may not have the IPFS gateway deployed yet."
                exit 1
            }

            local count
            count=$(echo "$response" | jq 'length')
            success "Server has ${count} CID mappings"

            if [ "$count" -gt 0 ]; then
                echo ""
                echo "$response" | jq -r '.[] | "  \(.ipfs_cid | .[0:20])... → \(.path)"' | head -20
                [ "$count" -gt 20 ] && echo "  ... and $((count - 20)) more"
            fi
            ;;

        dry-run)
            if [ ! -f "$MANIFEST" ] || [ ! -s "$MANIFEST" ]; then
                warn "Local manifest is empty: ${MANIFEST}"
                exit 1
            fi

            local count
            count=$(wc -l < "$MANIFEST" | tr -d ' ')
            info "Would push ${count} entries to ${lfs_url}/ipfs/manifest"
            echo ""
            jq -r '"  \(.ipfs_cid | .[0:20])... → \(.path)"' "$MANIFEST" | head -20
            [ "$count" -gt 20 ] && echo "  ... and $((count - 20)) more"
            ;;

        push)
            if [ ! -f "$MANIFEST" ] || [ ! -s "$MANIFEST" ]; then
                error "Local manifest is empty. Run ./tools/lfs-to-ipfs.sh --all first."
                exit 1
            fi

            # Get credentials
            local creds
            creds=$(get_credentials "$lfs_url")
            if [ -z "$creds" ]; then
                error "No LFS credentials found."
                echo "  The manifest push uses the same credentials as git lfs push."
                echo "  Set up credentials: git credential-store"
                exit 1
            fi

            local count
            count=$(wc -l < "$MANIFEST" | tr -d ' ')
            info "Pushing ${count} entries to ${lfs_url}/ipfs/manifest..."

            # Convert JSONL to JSON array and POST
            local json_body
            json_body=$(manifest_to_json)

            local response http_code
            response=$(curl -s -w "\n%{http_code}" -X POST "${lfs_url}/ipfs/manifest" \
                -u "$creds" \
                -H "Content-Type: application/json" \
                -d "$json_body" \
                2>/dev/null)

            http_code=$(echo "$response" | tail -1)
            local body
            body=$(echo "$response" | sed '$d')

            if [ "$http_code" = "200" ]; then
                local server_count
                server_count=$(echo "$body" | jq -r '.entries // 0')
                success "Manifest synced! Server now has ${server_count} CID mappings."
                echo ""
                echo "  Files are now accessible via:"
                echo "    ${lfs_url}/ipfs/<cid>"
                echo ""
                echo "  Example:"
                local first_cid
                first_cid=$(head -1 "$MANIFEST" | jq -r '.ipfs_cid')
                local first_path
                first_path=$(head -1 "$MANIFEST" | jq -r '.path')
                echo "    ${lfs_url}/ipfs/${first_cid}"
                echo "    → ${first_path}"
            else
                error "Push failed (HTTP ${http_code})"
                echo "  ${body}"
                exit 1
            fi
            ;;
    esac

    echo ""
}

main "$@"
