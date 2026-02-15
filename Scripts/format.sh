#!/bin/bash
# Format all Swift source files using SwiftFormat.
# Usage: ./Scripts/format.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if ! command -v swiftformat &> /dev/null; then
    echo "Error: swiftformat is not installed."
    echo "Install it with: brew install swiftformat"
    exit 1
fi

echo "Formatting Swift files..."
swiftformat "$PROJECT_ROOT/SequelPGApp" "$PROJECT_ROOT/SequelPGTests" \
    --config "$PROJECT_ROOT/.swiftformat"
echo "Done."
