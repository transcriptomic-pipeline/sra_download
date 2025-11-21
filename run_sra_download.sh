#!/bin/bash
#
# SRA Download Module - Main Script (single entry)
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

DEFAULT_INSTALL_DIR="${HOME}/softwares"
DEFAULT_OUTPUT_DIR="sra_fastq_download"

INPUT_SPEC=""
OUTPUT_DIR=""
THREADS=""
PARALLEL_JOBS=""
KEEP_SRA_CACHE="no"
INSTALL_BASE_DIR=""

usage() {
    cat <<EOF
SRA Download Module - FASTQ downloader using NCBI SRA Toolkit

Usage:
  bash run_sra_download.sh [OPTIONS]

Required:
  -i, --input VALUE   SRA IDs or file:
                      - Single ID: SRR12345678
                      - Comma list: "SRR1,SRR2,SRR3"
                      - File: sra_ids.txt (comma or newline separated)

Optional:
  -o, --output DIR    FASTQ output directory (default: prompt, then ${DEFAULT_OUTPUT_DIR})
  -t, --threads N     Threads per fasterq-dump (default: auto from CPU)
  -p, --parallel N    Number of accessions in parallel (default: auto from CPU)
      --install-dir D SRA Toolkit install directory (default: prompt, then ${DEFAULT_INSTALL_DIR})
      --keep-cache    Keep SRA cache (~/.ncbi, ~/ncbi)
  -h, --help          Show this help and exit
EOF
    exit 0
}

# ------------- CLI args -------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--input)
            INPUT_SPEC="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -t|--threads)
            THREADS="$2"
            shift 2
            ;;
        -p|--parallel)
            PARALLEL_JOBS="$2"
            shift 2
            ;;
        --install-dir)
            INSTALL_BASE_DIR="$2"
            INSTALL_BASE_DIR="${INSTALL_BASE_DIR/#\~/$HOME}"
            INSTALL_BASE_DIR="${INSTALL_BASE_DIR%/}"
            shift 2
            ;;
        --keep-cache)
            KEEP_SRA_CACHE="yes"
            shift
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

if [[ -z "$INPUT_SPEC" ]]; then
    log_error "No input provided. Use -i / --input."
    usage
fi

# ------------- Helpers --------------
auto_detect_cpu() {
    if command -v nproc &>/dev/null; then
        nproc
    else
        getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4
    fi
}

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

prompt_output_directory() {
    echo ""
    echo "========================================"
    echo "  FASTQ Output Directory"
    echo "========================================"
    echo ""
    log_info "Choose output directory for FASTQ files"
    echo "  1) ${DEFAULT_OUTPUT_DIR} (inside current directory)"
    echo "  2) Custom directory"
    echo ""
    read -p "Enter choice [1-2] (default: 1): " choice
    choice="${choice:-1}"

    case "$choice" in
        1)
            OUTPUT_DIR="${DEFAULT_OUTPUT_DIR}"
            ;;
        2)
            read -p "Enter output directory: " OUTPUT_DIR
            OUTPUT_DIR="${OUTPUT_DIR/#\~/$HOME}"
            OUTPUT_DIR="${OUTPUT_DIR%/}"
            ;;
        *)
            log_error "Invalid choice"
            exit 1
            ;;
    esac
}

ensure_install_and_tools() {
    # Ask for install dir if user didn't provide
    if [[ -z "$INSTALL_BASE_DIR" ]]; then
        prompt_install_directory
    fi

    local BIN_DIR="${INSTALL_BASE_DIR}/bin"
    PREFETCH_BIN="${BIN_DIR}/prefetch"
    FASTERQ_BIN="${BIN_DIR}/fasterq-dump"

    if [[ ! -x "$PREFETCH_BIN" || ! -x "$FASTERQ_BIN" ]]; then
        log_warning "SRA Toolkit not found in: ${INSTALL_BASE_DIR}"
        log_info "Running installer..."
        bash "${SCRIPT_DIR}/install.sh" --install-dir "$INSTALL_BASE_DIR"
        echo ""
        BIN_DIR="${INSTALL_BASE_DIR}/bin"
        PREFETCH_BIN="${BIN_DIR}/prefetch"
        FASTERQ_BIN="${BIN_DIR}/fasterq-dump"
    else
        log_success "Found existing SRA Toolkit in: ${INSTALL_BASE_DIR}"
    fi

    if [[ ! -x "$PREFETCH_BIN" || ! -x "$FASTERQ_BIN" ]]; then
        log_error "SRA Toolkit binaries not found after installation at: ${BIN_DIR}"
        exit 1
    fi

    export PREFETCH_BIN FASTERQ_BIN
}

detect_threads_and_parallel() {
    if [[ -z "${THREADS}" ]]; then
        local cores
        cores="$(auto_detect_cpu)"
        THREADS=$(( cores / 2 ))
        [[ "$THREADS" -lt 2 ]] && THREADS=2
    fi

    if [[ -z "${PARALLEL_JOBS}" ]]; then
        local cores
        cores="$(auto_detect_cpu)"
        PARALLEL_JOBS=$(( cores / THREADS ))
        [[ "$PARALLEL_JOBS" -lt 1 ]] && PARALLEL_JOBS=1
    fi
}

parse_input_ids() {
    local input="$1"
    SRA_IDS=()

    if [[ -f "$input" ]]; then
        input="$(realpath "$input")"
        log_info "Reading SRA IDs from file: $input"
        local content
        content="$(tr ',\r' ' \n' < "$input")"
        while read -r line; do
            [[ -z "$line" ]] && continue
            SRA_IDS+=("$line")
        done <<< "$content"
    else
        log_info "Parsing SRA IDs from input string"
        local cleaned
        cleaned="$(echo "$input" | tr -d ' ' | tr ',' '\n')"
        while read -r id; do
            [[ -z "$id" ]] && continue
            SRA_IDS+=("$id")
        done <<< "$cleaned"
    fi

    if [[ "${#SRA_IDS[@]}" -eq 0 ]]; then
        log_error "No valid SRA IDs parsed from input."
        exit 1
    fi
}

prepare_output_dir() {
    if [[ -z "$OUTPUT_DIR" ]]; then
        prompt_output_directory
    fi
    mkdir -p "$OUTPUT_DIR"
    cd "$OUTPUT_DIR"
    log_info "Using output directory: $(pwd)"
}

download_one() {
    local acc="$1"

    echo ""
    echo "========================================"
    log_info "Processing accession: $acc"
    echo "========================================"

    log_info "Downloading SRA data with prefetch..."
    echo -e "${YELLOW}[COMMAND]${NC} \"$PREFETCH_BIN\" \"$acc\" -O . --max-size 100G"
    "$PREFETCH_BIN" "$acc" -O . --max-size 100G

    log_info "Converting to FASTQ with fasterq-dump (threads=${THREADS})..."
    echo -e "${YELLOW}[COMMAND]${NC} \"$FASTERQ_BIN\" \"$acc\" -O . -t . -e \"$THREADS\""
    "$FASTERQ_BIN" "$acc" -O . -t . -e "$THREADS"

    if [[ -d "$acc" ]]; then
        log_info "Cleaning local SRA directory: $acc/"
        rm -rf "$acc"
    fi

    log_success "Finished accession: $acc"
}

export -f download_one
export THREADS YELLOW NC BLUE GREEN RED
export -f log_info log_success log_warning log_error
export PREFETCH_BIN FASTERQ_BIN

run_parallel_downloads() {
    local -n arr_ref="$1"
    local jobs="$2"
    log_info "Starting parallel downloads: ${#arr_ref[@]} accessions, ${jobs} jobs, ${THREADS} threads each."
    printf "%s\n" "${arr_ref[@]}" | xargs -r -n1 -P "$jobs" bash -c 'download_one "$@"' _
}

cleanup_cache() {
    if [[ "$KEEP_SRA_CACHE" == "yes" ]]; then
        log_info "Keeping SRA cache as requested."
        return
    fi
    for d in "$HOME/ncbi" "$HOME/.ncbi"; do
        if [[ -d "$d" ]]; then
            log_info "Removing SRA cache directory: $d"
            rm -rf "$d"
        fi
    done
}

main() {
    echo "========================================"
    echo "  SRA Download Module"
    echo "========================================"
    echo ""

    ensure_install_and_tools        # PROMPTS + INSTALLS if needed, then returns
    detect_threads_and_parallel
    parse_input_ids "$INPUT_SPEC"
    prepare_output_dir

    log_info "Installation directory: ${INSTALL_BASE_DIR}"
    log_info "CPU cores detected:    $(auto_detect_cpu)"
    log_info "Threads per accession: ${THREADS}"
    log_info "Parallel accessions:   ${PARALLEL_JOBS}"
    log_info "Total accessions:      ${#SRA_IDS[@]}"

    run_parallel_downloads SRA_IDS "$PARALLEL_JOBS"
    cleanup_cache

    echo ""
    log_success "FASTQ download complete."
    echo ""
    ls -lh *.fastq 2>/dev/null || log_warning "No .fastq files found (check logs for errors)."
}

main "$@"
