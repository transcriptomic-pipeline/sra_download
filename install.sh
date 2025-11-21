#!/bin/bash
#
# SRA Toolkit Installer
#

set -euo pipefail

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

DEFAULT_INSTALL_DIR="${HOME}/softwares"
DEFAULT_THREADS=4

INSTALL_BASE_DIR=""
THREADS="$DEFAULT_THREADS"

SRA_URL="https://ftp-trace.ncbi.nlm.nih.gov/sra/sdk/current/sratoolkit.current-ubuntu64.tar.gz"

CONFIG_DIR="${SCRIPT_DIR}/config"
CONFIG_FILE="${CONFIG_DIR}/install_paths.conf"

usage() {
    cat <<EOF
SRA Toolkit Installer

Usage:
  bash install_sra.sh [OPTIONS]

Options:
  --install-dir DIR   Installation directory (default: prompt)
  --threads N         Default threads (default: ${DEFAULT_THREADS})
  -h, --help          Show this help and exit
EOF
    exit 0
}

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
    echo "  SRA Toolkit Installation Directory"
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
            read -p "Enter custom installation directory: " INSTALL_BASE_DIR
            INSTALL_BASE_DIR="${INSTALL_BASE_DIR/#\~/$HOME}"
            INSTALL_BASE_DIR="${INSTALL_BASE_DIR%/}"
            ;;
        *)
            log_error "Invalid choice"
            exit 1
            ;;
    esac
}

check_existing_installation() {
    local bin_dir="${INSTALL_BASE_DIR}/bin"
    
    if [[ -x "${bin_dir}/prefetch" && -x "${bin_dir}/fasterq-dump" ]]; then
        log_success "SRA Toolkit already installed in: ${INSTALL_BASE_DIR}"
        
        # Save config
        mkdir -p "$CONFIG_DIR"
        cat > "$CONFIG_FILE" <<EOF
# SRA Toolkit Installation Paths
SRA_INSTALL_DIR="${INSTALL_BASE_DIR}"
PREFETCH_BIN="${bin_dir}/prefetch"
FASTERQ_BIN="${bin_dir}/fasterq-dump"
SRA_DEFAULT_THREADS="${THREADS}"
EOF
        
        # Update PATH in profile
        append_path_to_shell_profile "${bin_dir}"
        
        echo ""
        log_info "To use in current shell: export PATH=\"${bin_dir}:\$PATH\""
        return 0
    fi
    
    return 1
}

is_debian_like() {
    command -v apt-get &>/dev/null
}

install_package_if_missing_apt() {
    local pkg="$1"
    if dpkg -s "$pkg" &>/dev/null 2>&1; then
        return 0
    fi
    log_warning "Package '$pkg' not found. Installing via apt-get..."
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

    for tool in curl tar gzip; do
        if ! command -v "$tool" &>/dev/null; then
            log_warning "$tool not found."
            need_apt=1
        fi
    done

    if [[ "$need_apt" -eq 0 ]]; then
        log_success "All required dependencies already installed."
        return 0
    fi

    if ! is_debian_like; then
        log_error "Missing dependencies. Please install curl, tar, gzip manually."
        exit 1
    fi

    log_info "Installing missing dependencies..."
    command -v curl &>/dev/null || install_package_if_missing_apt curl
    command -v tar  &>/dev/null || install_package_if_missing_apt tar
    command -v gzip &>/dev/null || install_package_if_missing_apt gzip
    log_success "Dependencies installed."
}

append_path_to_shell_profile() {
    local bin_dir="$1"
    local profile_file="${HOME}/.bashrc"
    
    [[ ! -f "$profile_file" ]] && profile_file="${HOME}/.profile"
    
    local export_line="export PATH=\"${bin_dir}:\$PATH\""

    if grep -Fq "$export_line" "$profile_file" 2>/dev/null; then
        log_info "PATH already set in ${profile_file}"
    else
        echo "" >> "$profile_file"
        echo "# SRA Toolkit" >> "$profile_file"
        echo "$export_line" >> "$profile_file"
        log_success "Added to PATH in ${profile_file}"
    fi
}

install_sra_toolkit() {
    mkdir -p "$INSTALL_BASE_DIR"
    local BIN_DIR="${INSTALL_BASE_DIR}/bin"
    mkdir -p "$BIN_DIR"

    log_info "Downloading SRA Toolkit..."
    local TMP_TAR
    TMP_TAR="$(mktemp /tmp/sratoolkit.XXXXXX.tar.gz)"

    curl -L "$SRA_URL" -o "$TMP_TAR"

    log_info "Extracting..."
    tar -xzf "$TMP_TAR" -C "$INSTALL_BASE_DIR"
    rm -f "$TMP_TAR"

    local SRA_DIR
    SRA_DIR="$(find "$INSTALL_BASE_DIR" -maxdepth 1 -type d -name 'sratoolkit.*-ubuntu64' | head -n1)"
    if [[ -z "$SRA_DIR" ]]; then
        log_error "Failed to locate extracted directory"
        exit 1
    fi

    for tool in prefetch fasterq-dump vdb-config; do
        if [[ -x "${SRA_DIR}/bin/${tool}" ]]; then
            ln -sf "${SRA_DIR}/bin/${tool}" "${BIN_DIR}/${tool}"
        fi
    done

    log_success "SRA Toolkit installed in: $SRA_DIR"

    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
# SRA Toolkit Installation Paths
SRA_INSTALL_DIR="${INSTALL_BASE_DIR}"
SRA_DIR="${SRA_DIR}"
PREFETCH_BIN="${BIN_DIR}/prefetch"
FASTERQ_BIN="${BIN_DIR}/fasterq-dump"
SRA_DEFAULT_THREADS="${THREADS}"
EOF

    log_success "Configuration saved."
    append_path_to_shell_profile "$BIN_DIR"
}

main() {
    echo "========================================"
    echo "  SRA Toolkit Installer"
    echo "========================================"
    echo ""

    check_and_install_dependencies

    if [[ -z "$INSTALL_BASE_DIR" ]]; then
        prompt_install_directory
    else
        log_info "Using: $INSTALL_BASE_DIR"
    fi

    # Check if already installed
    if check_existing_installation; then
        echo ""
        log_success "Installation already complete. Nothing to do."
        exit 0
    fi

    # Install fresh
    install_sra_toolkit

    echo ""
    echo "========================================"
    echo "  Installation Complete"
    echo "========================================"
    echo ""
    log_success "Done. Start a new terminal or run: source ~/.bashrc"
}

main "$@"
