#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p target/native-tests
xcrun clang -fobjc-arc -fblocks -mmacosx-version-min=15.0 -Wall -Wextra -Werror \
  native/test-lifecycle.m -o target/native-tests/lifecycle \
  -framework AppKit -framework ScreenCaptureKit -framework AVFoundation \
  -framework CoreMedia -framework CoreGraphics
target/native-tests/lifecycle
