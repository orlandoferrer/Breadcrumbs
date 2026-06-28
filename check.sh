#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_CACHE="/private/tmp/FinderBreadcrumbsModuleCache"
REGRESSION_BINARY="/private/tmp/FinderBreadcrumbsEditingFocusRegressionTests"

cd "$SCRIPT_DIR"

swiftc \
  -typecheck \
  -module-cache-path "$MODULE_CACHE" \
  FinderBreadcrumbs/*.swift

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  FinderBreadcrumbs/AppConfig.swift \
  FinderBreadcrumbs/FinderAutomationService.swift \
  FinderBreadcrumbs/PathBarViewModel.swift \
  Tests/EditingFocusRegressionTests.swift \
  -o "$REGRESSION_BINARY"

"$REGRESSION_BINARY"

echo "All checks passed."
