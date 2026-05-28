#!/usr/bin/env bash
# =============================================================================
# setup-ipfs.sh — Install and configure Kubo (go-ipfs) for LFS↔IPFS bridging
# =============================================================================
#
# Usage:
#   ./tools/setup-ipfs.sh           # Install Kubo + init IPFS repo + start daemon
#   ./tools/setup-ipfs.sh --check   # Check if IPFS is already set up
#
# This script is idempotent — safe to run multiple times.
# =============================================================================

set -euo pipefail

# Minimum Kubo version we support
MIN_KUBO_VERSION="0.20.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}ℹ${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Check if a command exists
# ---------------------------------------------------------------------------
has_cmd() { command -v "$1" &>/dev/null; }

# ---------------------------------------------------------------------------
# Compare semver: returns 0 if $1 >= $2
# ---------------------------------------------------------------------------
version_gte() {
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i = 0; i < ${#ver2[@]}; i++)); do
        if ((10#${ver1[i]:-0} < 10#${ver2[i]:-0})); then
            return 1
        elif ((10#${ver1[i]:-0} > 10#${ver2[i]:-0})); then
            return 0
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Detect OS
# ---------------------------------------------------------------------------
detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)  echo "linux" ;;
        *)      echo "unknown" ;;
    esac
}

# ---------------------------------------------------------------------------
# Check if IPFS daemon is running
# ---------------------------------------------------------------------------
daemon_running() {
    ipfs swarm peers &>/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# --check mode: report status and exit
# ---------------------------------------------------------------------------
check_status() {
    echo ""
    echo -e "${BOLD}IPFS Status Check${NC}"
    echo "─────────────────────────────────────"

    # Binary
    if has_cmd ipfs; then
        local ver
        ver=$(ipfs --version 2>/dev/null | awk '{print $NF}')
        success "Kubo installed: v${ver}"
        if version_gte "$ver" "$MIN_KUBO_VERSION"; then
            success "Version >= ${MIN_KUBO_VERSION}"
        else
            warn "Version ${ver} is older than recommended ${MIN_KUBO_VERSION}"
        fi
    else
        error "Kubo (ipfs) not installed"
        echo "  Run: ./tools/setup-ipfs.sh"
        exit 1
    fi

    # Repo
    if [ -d "${IPFS_PATH:-$HOME/.ipfs}" ]; then
        success "IPFS repo initialized at ${IPFS_PATH:-$HOME/.ipfs}"
    else
        error "IPFS repo not initialized"
        echo "  Run: ipfs init"
        exit 1
    fi

    # Daemon
    if daemon_running; then
        success "IPFS daemon is running"
        local peer_count
        peer_count=$(ipfs swarm peers 2>/dev/null | wc -l | tr -d ' ')
        info "Connected to ${peer_count} peers"

        # Node identity
        local node_id
        node_id=$(ipfs id -f='<id>' 2>/dev/null)
        info "Node ID: ${node_id}"
    else
        warn "IPFS daemon is NOT running"
        echo "  Start with: ipfs daemon &"
    fi

    # Gateway
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:8080/ipfs/QmUNLLsPACCz1vLxQVkXqqLX5R1X345qqfHbsf67hvA3Nn" 2>/dev/null | grep -q "200\|301"; then
        success "Local gateway responding at http://localhost:8080"
    else
        warn "Local gateway not responding (expected if daemon is not running)"
    fi

    echo ""
    exit 0
}

# ---------------------------------------------------------------------------
# Install Kubo
# ---------------------------------------------------------------------------
install_kubo() {
    local os
    os=$(detect_os)

    case "$os" in
        macos)
            if has_cmd brew; then
                info "Installing Kubo via Homebrew..."
                brew install ipfs
            else
                error "Homebrew not found. Install Homebrew first:"
                echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
                echo ""
                echo "Or install Kubo manually:"
                echo "  https://docs.ipfs.tech/install/command-line/"
                exit 1
            fi
            ;;
        linux)
            info "Installing Kubo from official distribution..."
            local arch
            arch=$(uname -m)
            case "$arch" in
                x86_64)  arch="amd64" ;;
                aarch64) arch="arm64" ;;
                armv7l)  arch="arm" ;;
                *)
                    error "Unsupported architecture: ${arch}"
                    exit 1
                    ;;
            esac

            local tmpdir
            tmpdir=$(mktemp -d)
            local version="v0.28.0"
            local url="https://dist.ipfs.tech/kubo/${version}/kubo_${version}_linux-${arch}.tar.gz"

            info "Downloading ${url}..."
            curl -fsSL "$url" -o "${tmpdir}/kubo.tar.gz"

            info "Extracting..."
            tar -xzf "${tmpdir}/kubo.tar.gz" -C "$tmpdir"

            info "Installing to /usr/local/bin..."
            sudo bash "${tmpdir}/kubo/install.sh"

            rm -rf "$tmpdir"
            ;;
        *)
            error "Unsupported OS. Install Kubo manually:"
            echo "  https://docs.ipfs.tech/install/command-line/"
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    # Handle --check flag
    if [ "${1:-}" = "--check" ]; then
        check_status
    fi

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   IPFS Setup for LFS↔IPFS Bridge    ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo ""

    # Step 1: Check/Install Kubo
    if has_cmd ipfs; then
        local ver
        ver=$(ipfs --version 2>/dev/null | awk '{print $NF}')
        success "Kubo already installed: v${ver}"

        if ! version_gte "$ver" "$MIN_KUBO_VERSION"; then
            warn "Version ${ver} is older than recommended ${MIN_KUBO_VERSION}"
            echo "  Consider upgrading: brew upgrade ipfs (macOS) or reinstall"
        fi
    else
        info "Kubo not found — installing..."
        install_kubo
        success "Kubo installed: $(ipfs --version 2>/dev/null)"
    fi

    # Step 2: Initialize IPFS repo
    local ipfs_path="${IPFS_PATH:-$HOME/.ipfs}"
    if [ -d "$ipfs_path" ]; then
        success "IPFS repo already initialized at ${ipfs_path}"
    else
        info "Initializing IPFS repo..."
        ipfs init
        success "IPFS repo initialized at ${ipfs_path}"
    fi

    # Step 3: Start daemon if not running
    if daemon_running; then
        success "IPFS daemon already running"
    else
        info "Starting IPFS daemon in the background..."
        ipfs daemon &>/dev/null &
        local daemon_pid=$!

        # Wait for daemon to be ready (up to 15 seconds)
        local attempts=0
        while ! daemon_running && [ $attempts -lt 30 ]; do
            sleep 0.5
            attempts=$((attempts + 1))
        done

        if daemon_running; then
            success "IPFS daemon started (PID: ${daemon_pid})"
        else
            warn "Daemon may still be starting — check with: ipfs swarm peers"
        fi
    fi

    # Step 4: Print summary
    echo ""
    echo -e "${BOLD}Setup complete!${NC}"
    echo "─────────────────────────────────────"

    local node_id
    node_id=$(ipfs id -f='<id>' 2>/dev/null || echo "unknown")
    local peer_count
    peer_count=$(ipfs swarm peers 2>/dev/null | wc -l | tr -d ' ' || echo "0")

    echo "  Node ID:       ${node_id}"
    echo "  Peers:         ${peer_count}"
    echo "  API:           http://localhost:5001"
    echo "  Gateway:       http://localhost:8080"
    echo "  IPFS Path:     ${ipfs_path}"
    echo ""
    echo -e "${BOLD}Next steps:${NC}"
    echo "  1. Install git hooks:  ./tools/install-hooks.sh"
    echo "  2. Mirror to IPFS:     ./tools/lfs-to-ipfs.sh --all"
    echo "  3. View manifest:      ./tools/show-manifest.sh"
    echo ""
    echo "  See docs/IPFS-SETUP.md for more details."
    echo ""
}

main "$@"
