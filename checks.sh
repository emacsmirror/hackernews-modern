#!/bin/bash

# checks.sh - Run all quality checks on Emacs Lisp files
# Usage: ./checks.sh

set -e  # Exit on error

echo "=== ORG-SOCIAL.EL QUALITY CHECKS ==="
echo ""

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Track overall status
OVERALL_STATUS=0

# 1. Format all files
echo -e "${BLUE}[1/5] Formatting all Emacs Lisp files...${NC}"
format_file() {
    local file="$1"
    echo "  Formatting $file..."
    if emacs --batch "$file" --eval "(progn (emacs-lisp-mode) (indent-region (point-min) (point-max)) (save-buffer))" 2>&1 | grep -q "error"; then
        echo -e "${RED}  ✗ Failed to format $file${NC}"
        OVERALL_STATUS=1
    else
        echo -e "${GREEN}  ✓ Formatted $file${NC}"
    fi
}

# Format all org-social*.el files
for file in org-social*.el; do
    [ -f "$file" ] && format_file "$file"
done

# Format ui/*.el files
for file in ui/*.el; do
    [ -f "$file" ] && format_file "$file"
done

# Format ui/buffers/*.el files
for file in ui/buffers/*.el; do
    [ -f "$file" ] && format_file "$file"
done

echo ""

# 2. Run checkdoc
echo -e "${BLUE}[2/5] Running checkdoc...${NC}"
checkdoc_file() {
    local file="$1"
    echo "  Checking $file..."
    emacs --batch --eval "(progn (require 'checkdoc) (checkdoc-file \"$file\"))" 2>&1
}

# Check all org-social*.el files
for file in org-social*.el; do
    [ -f "$file" ] && checkdoc_file "$file"
done

# Check ui/*.el files
for file in ui/*.el; do
    [ -f "$file" ] && checkdoc_file "$file"
done

# Check ui/buffers/*.el files
for file in ui/buffers/*.el; do
    [ -f "$file" ] && checkdoc_file "$file"
done

echo -e "${GREEN}✓ Checkdoc completed${NC}"
echo ""

# 3. Run package-lint
echo -e "${BLUE}[3/5] Running package-lint...${NC}"

if [ -f "check-package-lint.sh" ]; then
    bash check-package-lint.sh
    echo -e "${GREEN}✓ Package-lint completed${NC}"
else
    echo -e "${YELLOW}⚠ check-package-lint.sh not found, skipping package-lint${NC}"
fi

echo ""

# 4. Run melpazoid
echo -e "${BLUE}[4/5] Running melpazoid...${NC}"

if command -v python3 >/dev/null 2>&1; then
    if [ ! -d "melpazoid" ]; then
        echo "  Cloning melpazoid..."
        git clone https://github.com/riscy/melpazoid.git 2>&1 | grep -v "Cloning" || true
    fi

    echo "  Running melpazoid checks..."
    for file in org-social*.el; do
        if [ -f "$file" ]; then
            echo "  Checking $file..."
            python3 melpazoid/melpazoid/melpazoid.py --no-clone "$file" 2>&1 || OVERALL_STATUS=1
        fi
    done

    echo -e "${GREEN}✓ Melpazoid completed${NC}"
else
    echo -e "${YELLOW}⚠ Python3 not found, skipping melpazoid${NC}"
fi

echo ""

# 5. Compile all files
echo -e "${BLUE}[5/5] Compiling all Emacs Lisp files...${NC}"
compile_file() {
    local file="$1"
    echo "  Compiling $file..."
    if emacs --batch -L . -L ui -L ui/buffers --eval "(setq byte-compile-error-on-warn nil)" -f batch-byte-compile "$file" 2>&1 | grep -i "error\|warning" | grep -v "Loading"; then
        echo -e "${YELLOW}  ⚠ Compilation warnings/errors in $file${NC}"
        OVERALL_STATUS=1
    else
        echo -e "${GREEN}  ✓ Compiled $file${NC}"
    fi
}

# Compile all org-social*.el files
for file in org-social*.el; do
    [ -f "$file" ] && compile_file "$file"
done

# Compile ui/*.el files
for file in ui/*.el; do
    [ -f "$file" ] && compile_file "$file"
done

# Compile ui/buffers/*.el files
for file in ui/buffers/*.el; do
    [ -f "$file" ] && compile_file "$file"
done

echo ""
echo "=== ALL CHECKS COMPLETED ==="

if [ $OVERALL_STATUS -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed!${NC}"
else
    echo -e "${RED}✗ Some checks failed or had warnings${NC}"
fi

exit $OVERALL_STATUS
