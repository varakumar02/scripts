#!/bin/bash

usage() {
    echo "Usage: $0 [-i input_dir] -o output_dir [-s]"
    echo "  -i  Input directory containing .ko files (default: ./out/modules)"
    echo "  -o  Output directory to copy .ko files to (required)"
    echo "  -s  Strip debug info from modules before copying"
    exit 1
}

INPUT_DIR="./out/modules"
OUTPUT_DIR=""
STRIP_DEBUG=0

while getopts "i:o:s" opt; do
    case $opt in
        i) INPUT_DIR="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        s) STRIP_DEBUG=1 ;;
        *) usage ;;
    esac
done

if [ -z "$OUTPUT_DIR" ]; then
    echo "Error: -o output_dir is required"
    usage
fi

if [ ! -d "$INPUT_DIR" ]; then
    echo "Error: Input directory '$INPUT_DIR' does not exist"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

count=0
find "$INPUT_DIR" -name "*.ko" -type f | while read -r ko; do
    filename=$(basename "$ko")
    cp "$ko" "$OUTPUT_DIR/$filename"
    if [ "$STRIP_DEBUG" -eq 1 ]; then
        llvm-strip --strip-debug "$OUTPUT_DIR/$filename"
    fi
    echo "  $filename"
    count=$((count + 1))
done

total=$(find "$INPUT_DIR" -name "*.ko" -type f | wc -l)
echo ""
echo "Copied $total .ko files to $OUTPUT_DIR"
