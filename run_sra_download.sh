#!/bin/bash
#
# SRA FASTQ Downloader with parallel processing
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

INPUT_SPEC=""
OUTPUT_DIR=""
THREADS=""
PARALLEL_JOBS=""
BIN_DIR=""

DEFAULT_OUTPUT_DIR="sra_fastq_download"

usage() {
    cat <<EOF
SRA FASTQ Downloader

Usage:
  bash download_fastq_sra.sh -i INPUT [OPTIONS]

Required:
  -i, --input VALUE   SRA IDs or file (SRR12345678, "SRR1,SRR2", or sra_ids.txt)

Optional:
  -o, --output DIR    Output directory (default: prompt, then ${DEFAULT_OUTPUT_DIR})
  -t, --threads N     Threads per accession for fasterq-dump (default: auto)
  -p, --parallel N    Number of accessions to process in parallel (default: auto)
      --bin-dir DIR   Toolkit bin directory (default: use PATH)
  -h, --help          Show help

Examples:
  bash download_fastq_sra.sh -i SRR12345678
  bash download_fastq_sra.sh -i sra_ids.txt
  bash download_fastq_sra.sh -i sra_ids.txt -o my_fastq -t 8 -p 2
EOF
    exit 0
}

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
        --bin-dir)
            BIN_DIR="${2%/}"
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

[[ -z "$INPUT_SPEC" ]] && { log_error "No input. Use -i"; usage; }

auto_detect_cpu() {
    command -v nproc &>/dev/null && nproc || echo 4
}

prompt_output_directory() {
    echo ""
    echo "========================================"
    echo "  FASTQ Output Directory"
    echo "========================================"
    echo ""
    log_info "Choose output directory for FASTQ files"
    echo "  1) ${DEFAULT_OUTPUT_DIR} (in current directory)"
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

[[ -n "$BIN_DIR" ]] && export PATH="${BIN_DIR}:$PATH"

command -v prefetch &>/dev/null || { log_error "prefetch not found. Install SRA Toolkit first."; exit 1; }
command -v fasterq-dump &>/dev/null || { log_error "fasterq-dump not found."; exit 1; }

# Auto-detect threads and parallel jobs
cores=$(auto_detect_cpu)

if [[ -z "$THREADS" ]]; then
    THREADS=$(( cores / 2 ))
    [[ $THREADS -lt 2 ]] && THREADS=2
fi

if [[ -z "$PARALLEL_JOBS" ]]; then
    PARALLEL_JOBS=$(( cores / THREADS ))
    [[ $PARALLEL_JOBS -lt 1 ]] && PARALLEL_JOBS=1
fi

# Parse input
SRA_IDS=()
if [[ -f "$INPUT_SPEC" ]]; then
    log_info "Reading from: $INPUT_SPEC"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//,/ }"
        for id in $line; do
            [[ -n "$id" ]] && SRA_IDS+=("$id")
        done
    done < "$INPUT_SPEC"
else
    log_info "Parsing input string"
    IFS=',' read -ra TEMP_IDS <<< "$INPUT_SPEC"
    for id in "${TEMP_IDS[@]}"; do
        id="${id// /}"
        [[ -n "$id" ]] && SRA_IDS+=("$id")
    done
fi

[[ ${#SRA_IDS[@]} -eq 0 ]] && { log_error "No valid SRA IDs."; exit 1; }

# Prompt for output directory if not provided
if [[ -z "$OUTPUT_DIR" ]]; then
    prompt_output_directory
fi

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

echo ""
echo "========================================"
echo "  SRA FASTQ Downloader"
echo "========================================"
echo ""
log_info "Output directory: $(pwd)"
log_info "CPU cores detected: $cores"
log_info "Threads per accession: $THREADS"
log_info "Parallel accessions: $PARALLEL_JOBS"
log_info "Total accessions: ${#SRA_IDS[@]}"
echo ""

# Function to download one accession
download_one() {
    local acc="$1"
    local threads="$2"
    
    echo "========================================"
    log_info "Processing: $acc"
    echo "========================================"
    
    log_info "Downloading..."
    prefetch "$acc" -O . --max-size 100G
    
    log_info "Converting to FASTQ (threads=${threads})..."
    fasterq-dump "$acc" -O . -t . -e "$threads" --split-files
    
    [[ -d "$acc" ]] && rm -rf "$acc"
    
    log_success "Finished: $acc"
    echo ""
}

export -f download_one
export -f log_info log_success log_error
export BLUE GREEN RED NC YELLOW THREADS

# Run parallel downloads
printf "%s\n" "${SRA_IDS[@]}" | xargs -I {} -P "$PARALLEL_JOBS" bash -c 'download_one "$@"' _ {} "$THREADS"

echo ""
log_success "All downloads complete!"
echo ""
ls -lh *.fastq 2>/dev/null || log_warning "No .fastq files found"

# Cleanup cache
for d in "$HOME/ncbi" "$HOME/.ncbi"; do
    if [[ -d "$d" ]]; then
        log_info "Removing SRA cache: $d"
        rm -rf "$d"
    fi
done
