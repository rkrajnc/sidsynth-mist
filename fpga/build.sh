#!/bin/sh

# build_release.sh - compile the self-contained release Quartus project.
#
# Quartus 13.1 runs inside the raetro/quartus:13.1 image -- the native installed
# Quartus 13.0sp1 crashes routing the MiSTer SID core
#
# Usage:  ./build.sh

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)   # rel/fpga
REL_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)       # rel (mounted at /build)

mkdir -p "$SCRIPT_DIR/build"

docker run --rm \
  -v "$REL_ROOT:/build" \
  -w /build/fpga/build \
  -e HOME=/tmp \
  ghcr.io/raetro/quartus:13.1 \
  quartus_sh --64bit --flow compile /build/fpga/sidsynth_mist
