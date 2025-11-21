#!/bin/bash
#
# SRA Download Module - Main Script
#
# This script:
#   - Checks for SRA Toolkit (via config/install_paths.conf)
#   - If missing, automatically runs install.sh
#   - Detects CPU cores and sets sensible defaults for threads
#   - Supports parallel downloads across accessions
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
CONFIG_DIR="${SCRIPT_DIR}/config"
CONFIG_FILE="${CONFIG_DIR}/install_paths.conf"

INPUT_SPEC=""
OUTPUT_DIR="sra_fastq_download"
THREADS=""           # threads per fasterq-dump
PARALLEL_JOBS=""     # number of accessions in parallel
KEEP_SRA_CACHE="no"

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
  -o, --output DIR    Output directory (default: sra_fastq_download)
  -t, --threads N     Threads per fasterq-dump process (default: auto)
  -p, --parallel N    Number of accessions to process in parallel (default: auto)
      --keep-cache    Keep SRA cache (~/.ncbi, ~/ncbi) after download
  -h, --help          Show this help and exit

Examples:
  bash run_sra_download.sh -i SRR12345678
  bash run_sra_download.sh -i "SRR1,SRR2" -o fastq_dir -t 8 -p 2
  bash run_sra_download.sh -i sra_ids.txt --keep-cache
EOF
    exit 0
}

# Parse CLI args
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

auto_detect_cpu() {
    local cores
    if command -v nproc &>/dev/null; then
        cores="$(nproc)"
    else
        cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
    fi
    echo "$cores"
}

load_config_or_install() {
    # Try to load config
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    # If tools not usable, run installer
    if [[ -z "${PREFETCH_BIN:-}" || ! -x "${PREFETCH_BIN:-/nonexistent}" || -z "${FASTERQ_BIN:-}" || ! -x "${FASTERQ_BIN:-/nonexistent}" ]]; then
        log_warning "SRA Toolkit not configured or not found."
        log_info "Running installer..."
        bash "${SCRIPT_DIR}/install.sh"
        echo ""

        # Reload config after install
        if [[ -f "$CONFIG_FILE" ]]; then
            # shellcheck disable=SC1090
            source "$CONFIG_FILE"
        else
            log_error "Installation finished but configuration file not found: $CONFIG_FILE"
            exit 1
        fi
    fi

    # Final sanity check
    if [[ -z "${PREFETCH_BIN:-}" || ! -x "${PREFETCH_BIN}" ]]; then
        log_error "prefetch binary not found or not executable: ${PREFETCH_BIN:-unset}"
        exit 1
    fi
    if [[ -z "${FASTERQ_BIN:-}" || ! -x "${FASTERQ_BIN}" ]]; then
        log_error "fasterq-dump binary not found or not executable: ${FASTERQ_BIN:-unset}"
        exit 1
    fi
}

detect_threads_and_parallel() {
    # THREADS: if not provided, auto from config or CPU
    if [[ -z "${THREADS}" ]]; then
        if [[ -n "${SRA_DEFAULT_THREADS:-}" ]]; then
            THREADS="${SRA_DEFAULT_THREADS}"
        else
            local cores
            cores="$(auto_detect_cpu)"
            THREADS=$(( cores / 2 ))
            [[ "$THREADS" -lt 2 ]] && THREADS=2
        fi
    fi

    # PARALLEL_JOBS: if not provided, auto from CPU and THREADS
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
export PREFETCH_BIN FASTERQ_BIN THREADS YELLOW NC BLUE GREEN RED
export -f log_info log_success log_warning log_error

run_parallel_downloads() {
    local -n arr_ref="$1"
    local jobs="$2"

    log_info "Starting parallel downloads: ${#arr_ref[@]} accessions, ${jobs} jobs, ${THREADS} threads each."

    printf "%s\n" "${arr_ref[@]}" | xargs -r -n1 -P "$jobs" bash -c 'download_one "$@"' _
}

cleanup_cache() {
    if [[ "$KEEP_SRA_CACHE" == "yes" ]]; then
        log_info "Keeping SRA cache as requested."
        return 0
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

    load_config_or_install
    detect_threads_and_parallel
    parse_input_ids "$INPUT_SPEC"
    prepare_output_dir

    log_info "CPU cores detected: $(auto_detect_cpu)"
    log_info "Threads per accession (fasterq-dump): $THREADS"
    log_info "Parallel accessions: $PARALLEL_JOBS"
    log_info "Total accessions: ${#SRA_IDS[@]}"

    run_parallel_downloads SRA_IDS "$PARALLEL_JOBS"
    cleanup_cache

    echo ""
    log_success "FASTQ download complete."
    echo ""
    ls -lh *.fastq 2>/dev/null || log_warning "No .fastq files found (check logs for errors)."
}

main "$@"
