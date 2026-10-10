#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
osacompile -o "build/Drive Index Utility.app" "Sources/Drive Index Utility.applescript"
