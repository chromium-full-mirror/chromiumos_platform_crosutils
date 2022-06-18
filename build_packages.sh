#!/bin/bash

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script is being deprecated and moved to chromite/ by 2022-06-30.
# Do not add any references to this script.
# Please reach out if you have any questions.

. "$(dirname "$0")/common.sh" || exit 1

if [[ "$1" != "--script-is-run-only-by-chromite-and-not-users" ]]; then
  die_notrace 'This script must not be run by users.' \
    'Please run `build_packages` from $PATH (in chromite/bin/) instead.'
fi
# Discard the magic marker flag.
shift

# Developer-visible flags.
DEFINE_string board "${DEFAULT_BOARD}" \
  "The board to build packages for."

# The --board_root flag specifies the environment variables ROOT and PKGDIR.
# This allows fetching and emerging of all packages to specified board_root.
# Note that --board_root will setup the board normally in /build/$BOARD, if it's
# not setup yet. It also expects the toolchain to already be installed in the
# board_root. --usepkgonly and --norebuild are required, because building is not
# supported when board_root is set.
# enforce this)."
DEFINE_string board_root "" \
  "Emerge packages to board_root."

# --run_goma option is designed to be used on bots.
# If you're trying to build pacakges with goma in your local dev env, this is
# *not* the option you're looking for. Please see comments below.
# This option; 1) starts goma, 2) builds packages (expecting that goma is
# used), then 3) stops goma explicitly.
# 3) is a request from the goma team, so that stats/logs can be taken.
# Note: GOMA_DIR and GOMA_SERVICE_ACCOUNT_JSON_FILE are expected to be passed
# via env var.
#
# In local dev env cases, compiler_proxy is expected to keep running.
# In such a case;
#   $ python ${GOMA_DIR}/goma_ctl.py ensure_start
#   $ ./build_packages (... and options without --run_goma ...)
# is an expected commandline sequence. If you set --run_goma flag while
# compiler_proxy is already running, the existing compiler_proxy will be
# stopped.
DEFINE_boolean run_goma "${FLAGS_FALSE}" \
  "If set to true, (re)starts goma, builds packages, and then stops goma."

# This option is for building chrome remotely.
#1) starts reproxy 2) builds chrome with reproxy and 3) stops reproxy so
# logs/stats can be collected.
# Note: RECLIENT_DIR and REPROXY_CFG are expected to be passed via env var.
DEFINE_boolean run_remoteexec "${FLAGS_FALSE}" \
  "If set to true, starts RBE reproxy, builds packages, and then stops reproxy."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Die on any errors.
switch_to_strict_mode

# Setup all the emerge command/flags.
# TODO(xcl): Remove once reverse dependency logic is migrated to Python.
# During the migration, temporarily get the emerge flags from a envvar set in
# Python.
EMERGE_FLAGS=( ${BUILD_PACKAGES_EMERGE_FLAGS} )

EMERGE_CMD=(
  "${CHROMITE_BIN}/parallel_emerge"
  --board=${FLAGS_board}
)

# Figure out which packages we should be building.
PACKAGES=( "$@" )
# TODO(xcl): During the migration, temporarily get the force local build
# packages from a envvar set in Python.
FORCE_LOCAL_BUILD_PKGS=( ${BUILD_PACKAGES_FORCE_LOCAL_BUILD_PKGS} )

if [[ -n "${FLAGS_board_root}" ]]; then
  export ROOT="${FLAGS_board_root}"
  export PORTAGE_CONFIGROOT="${ROOT}"
  export SYSROOT="${ROOT}"
  export PKGDIR="${ROOT}"/packages
fi

if [[ ${#FORCE_LOCAL_BUILD_PKGS[@]} -gt 0 ]]; then
  EMERGE_FLAGS+=(
    --reinstall-atoms="${FORCE_LOCAL_BUILD_PKGS[*]}"
    --usepkg-exclude="${FORCE_LOCAL_BUILD_PKGS[*]}"
  )
fi

# A list of critical system packages that should never be incidentally
# reinstalled as a side effect of build_packages. All packages in this list
# are special cased to prefer matching installed versions, overriding the
# typical logic of upgrading to the newest available version.
#
# This list can't include any package that gets installed to a board!
# Packages such as LLVM or binutils must not be in this list as the normal
# rebuild logic must still apply to them for board targets.
#
# TODO(crbug/1050752): Remove this list and the corresponding arguments
# to `emerge` below once we figure out how to exclude toolchain packages from
# being upgraded transitively via BDEPEND relations.
CRITICAL_SDK_PACKAGES=(
  "dev-embedded/hps-sdk"
  "dev-lang/rust"
  "dev-lang/go"
  "sys-libs/glibc"
  "sys-devel/gcc"
)

info "Merging board packages now"
(

  # Start reproxy for remote execution of building chrome.
  if [[ "${FLAGS_run_remoteexec}" -eq "${FLAGS_TRUE}" ]]; then
    info "Starting RBE reproxy."
    bootstrap="${RECLIENT_DIR}/bootstrap --cfg=${REPROXY_CFG} \
      --re_proxy=${RECLIENT_DIR}/reproxy"
    ${bootstrap}
    trap "${bootstrap} --shutdown" EXIT
  # Support goma on bots. This has to run in subshell, otherwise EXIT trap
  # handler is overwritten.
  elif [[ "${FLAGS_run_goma}" -eq "${FLAGS_TRUE}" ]]; then
    info "Starting goma compiler_proxy."
    goma_ctl="${GOMA_DIR:-${HOME}/goma}/goma_ctl.py"
    "${goma_ctl}" restart
    trap "'${goma_ctl}' stop" EXIT
  fi

  info_run sudo -E "${EMERGE_CMD[@]}" "${EMERGE_FLAGS[@]}" "${PACKAGES[@]}" \
    --useoldpkg-atoms="${CRITICAL_SDK_PACKAGES[*]}" \
    --rebuild-exclude="${CRITICAL_SDK_PACKAGES[*]}"
)
