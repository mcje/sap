#!/bin/bash
# Run sap integration tests
# Usage: ./tests/run_integration.sh

set -e

cd "$(dirname "$0")/.."

echo "Running sap integration tests..."
nvim --headless -u tests/minimal_init.lua -l tests/integration_runner.lua

echo ""
echo "Running unit tests..."
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}" 2>&1 | grep -E "(Success|Failed|Errors):"
