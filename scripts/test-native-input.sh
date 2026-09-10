#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mkdir -p .build/native-input-tests
clang -Wall -Wextra -Werror -I Sources/LeverInputState/include \
  Sources/LeverInputState/LeverInputState.c Tests/NativeInputTests/main.c \
  -o .build/native-input-tests/run
.build/native-input-tests/run
