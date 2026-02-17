#!/bin/bash
# Check package-lint for all .el files

set -e

# Find all .el files
EL_FILES=$(find . -name "*.el" -not -path "*/.*" -not -path "*/elpa/*" -not -path "*/test/*")

if [ -z "$EL_FILES" ]; then
    echo "No .el files found"
    exit 0
fi

# Run package-lint
emacs --batch \
    --eval "(progn (require 'package) (add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t) (package-initialize) (unless (package-installed-p 'package-lint) (package-refresh-contents) (package-install 'package-lint)) (require 'package-lint))" \
    --eval "(setq package-lint-batch-fail-on-warnings nil)" \
    -f package-lint-batch-and-exit \
    $EL_FILES

echo "package-lint completed successfully"
