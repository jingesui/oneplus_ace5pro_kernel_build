#!/usr/bin/env bash
# build_android15.sh — OnePlus Ace 5 Pro, Android 15 (OxygenOS 15), kernel 6.6.66
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/build_common.sh"
BRANCH="oneplus/sm8750_v_15.0.0_oneplus_ace5_pro"
LOCALVERSION="-android15-8-g29d86c5fc9dd-abogki428889875-4k"
do_build