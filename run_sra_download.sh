#!/bin/bash
#
# Download FASTQ files from SRA using SRA Toolkit
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

INPUT_SPEC=""
OUTPUT_DIR="sra_fastq_download"
THREADS=""
BIN_DIR=""

usage() {
    cat <<EOF
SRA FASTQ Downloader

Usage:
  bash download_fastq_sra.sh [OPTIONS]

Required:
  -i, --input VALUE   SRA IDs or file:
                      - Single ID: SRR12345678
                      - Comma list: "SRR1,SRR2,SRR3"
                      - File: sra_ids.txt (comma or newline separated)

Optional:
  -o, --output DIR    Output directory for FASTQs (default: sra_fastq_download)
  -t, --threads N     Threads for fasterq-dump (default: auto from CPU)
      --bin-dir DIR   Directory containing prefetch and fasterq-dump
                       (default: use PATH)
  -h, --help          Show this help and exit

Examples:
  bash download_fastq_sra.sh -i SRR12345678
  bash download_fastq_sra.sh -i sra_ids.txt -o fastq_out --bin-dir /home/user/softwares/bin
EOF
    exit 0
}

# ---- CLI args ----
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
        --bin-dir)
            BIN_DIR="$2"
            BIN_DIR="${BIN_DIR/#\~/$HOME}"
            BIN_DIR="${BIN_DIR%/}"
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

if [[ -z "$INPUT_SPEC" ]]; then
    log_error "No input provided. Use -i / --input."
    usage
fi

auto_detect_cpu() {
    if command -v nproc &>/dev/null; then
        nproc
    else
        getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4
    fi
}

ensure_tools_on_path() {
    if [[ -n "$BIN_DIR" ]]; then
        export PATH="${BIN_DIR}:$PATH"
    fi

    if ! command -v prefetch &>/dev/null; then
        log_error "prefetch not found in PATH. Install SRA Toolkit or use --bin-dir."
        exit 1
    fi
    if ! command -v fasterq-dump &>/dev/null; then
        log_error "fasterq-dump not found in PATH. Install SRA Toolkit or use --bin-dir."
        exit 1
    fi
}

detect_threads() {
    if [[ -z "${THREADS}" ]]; then
        local cores
        cores="$(auto_detect_cpu)"
        THREADS=$(( cores / 2 ))
        [[ "$THREADS" -lt 2 ]] && THREADS=2
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
    echo -e "${YELLOW}[COMMAND]${NC} prefetch \"$acc\" -O . --max-size 100G"
    prefetch "$acc" -O . --max-size 100G

    log_info "Converting to FASTQ with fasterq-dump (threads=${THREADS})..."
    echo -e "${YELLOW}[COMMAND]${NC} fasterq-dump \"$acc\" -O . -t . -e \"$THREADS\""
    fasterq-dump "$acc" -O . -t . -e "$THREADS"

    if [[ -d "$acc" ]]; then
        log_info "Cleaning local SRA directory: $acc/"
        rm -rf "$acc"
    fi

    log_success "Finished accession: $acc"
}

# ------------- MAIN -----------------
echo "========================================"
echo "  SRA FASTQ Downloader"
echo "========================================"
echo ""

ensure_tools_on_path
detect_threads
parse_input_ids "$INPUT_SPEC"
prepare_output_dir

log_info "Threads for fasterq-dump: ${THREADS}"
log_info "Total accessions: ${#SRA_IDS[@]}"

for acc in "${SRA_IDS[@]}"; do
    download_one "$acc"
done

echo ""
log_success "FASTQ download complete."
echo ""
ls -lh *.fastq 2>/dev/null || log_warning "No .fastq files found (check logs for errors)."
