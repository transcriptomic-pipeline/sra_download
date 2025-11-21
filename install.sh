#!/bin/bash
#
# SRA Download Module - Installation Script
# (Usually called automatically from run_sra_download.sh)
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Defaults
DEFAULT_INSTALL_DIR="${HOME}/softwares"
DEFAULT_THREADS=4

INSTALL_BASE_DIR=""
THREADS="$DEFAULT_THREADS"

# SRA Toolkit URL (Ubuntu 64-bit)
SRA_URL="https://ftp-trace.ncbi.nlm.nih.gov/sra/sdk/current/sratoolkit.current-ubuntu64.tar.gz"

CONFIG_DIR="${SCRIPT_DIR}/config"
CONFIG_FILE="${CONFIG_DIR}/install_paths.conf"

usage() {
    cat <<EOF
SRA Download Module - Installation

Usually you don't call this directly; run_sra_download.sh will call it
if SRA Toolkit is missing.

Usage:
  bash install.sh [OPTIONS]

Options:
  --install-dir DIR   Installation directory (default: ${DEFAULT_INSTALL_DIR})
  --threads N         Default threads for fasterq-dump (default: ${DEFAULT_THREADS})
  -h, --help          Show this help and exit
EOF
    exit 0
}

# Parse CLI args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir)
            INSTALL_BASE_DIR="$2"
            INSTALL_BASE_DIR="${INSTALL_BASE_DIR/#\~/$HOME}"
            INSTALL_BASE_DIR="${INSTALL_BASE_DIR%/}"
            shift 2
            ;;
        --threads)
            THREADS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

prompt_install_directory() {
    echo ""
    echo "========================================"
    echo "  Installation Directory"
    echo "========================================"
    echo ""
    log_info "Choose installation directory for SRA Toolkit"
    echo "  1) ${DEFAULT_INSTALL_DIR} (recommended)"
    echo "  2) Custom directory"
    echo ""
    read -p "Enter choice [1-2] (default: 1): " choice
    choice="${choice:-1}"

    case "$choice" in
        1)
            INSTALL_BASE_DIR="${DEFAULT_INSTALL_DIR}"
            ;;
        2)
            read -p "Enter custom directory: " INSTALL_BASE_DIR
            INSTALL_BASE_DIR="${INSTALL_BASE_DIR/#\~/$HOME}"
            INSTALL_BASE_DIR="${INSTALL_BASE_DIR%/}"
            ;;
        *)
            log_error "Invalid choice"
            exit 1
            ;;
    esac
}

check_existing_install() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        if [[ -n "${PREFETCH_BIN:-}" && -x "$PREFETCH_BIN" && -n "${FASTERQ_BIN:-}" && -x "$FASTERQ_BIN" ]]; then
            log_success "Existing SRA Toolkit detected: $FASTERQ_BIN"
            return 0
        fi
    fi
    return 1
}

is_debian_like() {
    if command -v apt-get &>/dev/null; then
        return 0
    fi
    return 1
}

install_package_if_missing_apt() {
    local pkg="$1"
    if dpkg -s "$pkg" &>/dev/null; then
        return 0
    fi
    log_warning "Package '$pkg' not found. Installing via apt-get (requires sudo)..."
    sudo apt-get update -y
    sudo apt-get install -y "$pkg"
}

check_and_install_dependencies() {
    echo ""
    echo "========================================"
    echo "  Checking Dependencies"
    echo "========================================"
    echo ""

    local need_apt=0

    # curl
    if ! command -v curl &>/dev/null; then
        log_warning "curl not found."
        need_apt=1
    fi

    # tar
    if ! command -v tar &>/dev/null; then
        log_warning "tar not found."
        need_apt=1
    fi

    # basic tools (optional, but nice)
    if ! command -v gzip &>/dev/null; then
        log_warning "gzip not found."
        need_apt=1
    fi

    if [[ "$need_apt" -eq 0 ]]; then
        log_success "All required dependencies already installed."
        return 0
    fi

    if ! is_debian_like; then
        log_error "Missing dependencies (curl/tar/gzip) and this installer only knows how to use apt-get."
        log_error "Please install the missing tools manually and re-run install.sh."
        exit 1
    fi

    log_info "Installing missing dependencies via apt-get..."
    # Install individually so dpkg -s checks are respected
    if ! command -v curl &>/dev/null; then
        install_package_if_missing_apt "curl"
    fi
    if ! command -v tar &>/dev/null; then
        install_package_if_missing_apt "tar"
    fi
    if ! command -v gzip &>/dev/null; then
        install_package_if_missing_apt "gzip"
    fi

    log_success "Dependency installation complete."
}

install_sra_toolkit() {
    mkdir -p "$INSTALL_BASE_DIR"
    local BIN_DIR="${INSTALL_BASE_DIR}/bin"
    mkdir -p "$BIN_DIR"

    log_info "Downloading SRA Toolkit from:"
    log_info "  $SRA_URL"
    local TMP_TAR
    TMP_TAR="$(mktemp "${TMPDIR:-/tmp}/sratoolkit.XXXXXX.tar.gz")"

    curl -L "$SRA_URL" -o "$TMP_TAR"

    log_info "Extracting SRA Toolkit..."
    tar -xzf "$TMP_TAR" -C "$INSTALL_BASE_DIR"
    rm -f "$TMP_TAR"

    local SRA_DIR
    SRA_DIR="$(find "$INSTALL_BASE_DIR" -maxdepth 1 -type d -name 'sratoolkit.*-ubuntu64' | head -n1)"
    if [[ -z "$SRA_DIR" ]]; then
        log_error "Failed to locate extracted SRA Toolkit directory"
        exit 1
    fi

    for tool in prefetch fasterq-dump vdb-config; do
        if [[ -x "${SRA_DIR}/bin/${tool}" ]]; then
            ln -sf "${SRA_DIR}/bin/${tool}" "${BIN_DIR}/${tool}"
        else
            log_warning "Tool not found in SRA Toolkit: ${tool}"
        fi
    done

    log_success "SRA Toolkit installed in: $SRA_DIR"

    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
# SRA Download Module - Installation Paths
SRA_INSTALL_DIR="${INSTALL_BASE_DIR}"
SRA_DIR="${SRA_DIR}"
PREFETCH_BIN="${BIN_DIR}/prefetch"
FASTERQ_BIN="${BIN_DIR}/fasterq-dump"
VDB_CONFIG_BIN="${BIN_DIR}/vdb-config"
SRA_DEFAULT_THREADS="${THREADS}"
EOF

    log_success "Configuration saved: $CONFIG_FILE"

    echo ""
    echo "To use SRA Toolkit from any terminal, add this to your shell config:"
    echo ""
    echo "  export PATH=\"${BIN_DIR}:\$PATH\""
    echo ""
}

main() {
    echo "========================================"
    echo "  SRA Download Module - Installation"
    echo "========================================"
    echo ""

    if check_existing_install; then
        log_info "Using existing installation."
        return 0
    fi

    check_and_install_dependencies

    if [[ -z "$INSTALL_BASE_DIR" ]]; then
        prompt_install_directory
    else
        log_info "Using installation directory from CLI: $INSTALL_BASE_DIR"
    fi

    install_sra_toolkit

    echo ""
    echo "========================================"
    echo "  Installation Complete"
    echo "========================================"
    echo ""
    log_success "SRA Toolkit installation finished."
}

main "$@"
