#!/bin/bash
#
# SRA FASTQ Downloader
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
OUTPUT_DIR="sra_fastq_download"
THREADS=""
BIN_DIR=""

usage() {
    cat <<EOF
SRA FASTQ Downloader

Usage:
  bash download_fastq_sra.sh -i INPUT [OPTIONS]

Required:
  -i, --input VALUE   SRA IDs or file (SRR12345678, "SRR1,SRR2", or sra_ids.txt)

Optional:
  -o, --output DIR    Output directory (default: sra_fastq_download)
  -t, --threads N     Threads for fasterq-dump (default: auto)
      --bin-dir DIR   Toolkit bin directory (default: use PATH)
  -h, --help          Show help

Examples:
  bash download_fastq_sra.sh -i SRR12345678
  bash download_fastq_sra.sh -i sra_ids.txt -o my_fastq -t 16
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

[[ -n "$BIN_DIR" ]] && export PATH="${BIN_DIR}:$PATH"

command -v prefetch &>/dev/null || { log_error "prefetch not found. Install SRA Toolkit first."; exit 1; }
command -v fasterq-dump &>/dev/null || { log_error "fasterq-dump not found."; exit 1; }

[[ -z "$THREADS" ]] && THREADS=$(( $(auto_detect_cpu) / 2 )) && [[ $THREADS -lt 2 ]] && THREADS=2

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

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"
log_info "Output directory: $(pwd)"

echo "========================================"
echo "  SRA FASTQ Downloader"
echo "========================================"
echo ""
log_info "Threads: $THREADS"
log_info "Total accessions: ${#SRA_IDS[@]}"
echo ""

for acc in "${SRA_IDS[@]}"; do
    echo "========================================"
    log_info "Processing: $acc"
    echo "========================================"
    
    log_info "Downloading..."
    prefetch "$acc" -O . --max-size 100G
    
    log_info "Converting to FASTQ..."
    fasterq-dump "$acc" -O . -t . -e "$THREADS"
    
    [[ -d "$acc" ]] && rm -rf "$acc"
    
    log_success "Finished: $acc"
    echo ""
done

log_success "All downloads complete!"
ls -lh *.fastq 2>/dev/null || log_warning "No .fastq files found"
