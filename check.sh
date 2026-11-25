#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_CACHE="/private/tmp/FinderBreadcrumbsModuleCache"
REGRESSION_BINARY="/private/tmp/FinderBreadcrumbsEditingFocusRegressionTests"

cd "$SCRIPT_DIR"

swiftc \
  -swift-version 6 \
  -typecheck \
  -module-cache-path "$MODULE_CACHE" \
  FinderBreadcrumbs/*.swift

swiftc \
  -swift-version 6 \
  -module-cache-path "$MODULE_CACHE" \
  FinderBreadcrumbs/AppConfig.swift \
  FinderBreadcrumbs/AccessibilityPermissionManager.swift \
  FinderBreadcrumbs/DragToInstallVolumeDetector.swift \
  FinderBreadcrumbs/FinderAutomationService.swift \
  FinderBreadcrumbs/FinderWindowTracker.swift \
  FinderBreadcrumbs/HotKeyManager.swift \
  FinderBreadcrumbs/LoginItemManager.swift \
  FinderBreadcrumbs/OverlayWindowController.swift \
  FinderBreadcrumbs/PathBarView.swift \
  FinderBreadcrumbs/PathBarViewModel.swift \
  FinderBreadcrumbs/SettingsWindowController.swift \
  Tests/EditingFocusRegressionTests.swift \
  -o "$REGRESSION_BINARY"

"$REGRESSION_BINARY"

echo "All checks passed."
