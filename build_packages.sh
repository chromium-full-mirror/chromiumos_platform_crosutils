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
DEFINE_boolean withrevdeps "${FLAGS_TRUE}" \
  "Calculate reverse dependencies on changed ebuilds."
DEFINE_boolean cleanbuild "${FLAGS_FALSE}" \
  "Perform a clean build; delete sysroot if it exists before building."

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

# Chrome packages that need to be treated the same. These are the chrome and
# chrome follow-on packages that share the same version as chrome and are
# updated in lock step.
CHROME_PACKAGES=(
  "chromeos-base/chromeos-chrome"
  "chromeos-base/chrome-icu"
)

BOARD_ROOT="${FLAGS_board_root:-/build/${FLAGS_board}}"

# Skip revdeps when we don't already have a built sysroot.
if [[ "${FLAGS_cleanbuild}" -eq "${FLAGS_TRUE}" || ! -d "${BOARD_ROOT}" ]]; then
  SKIP_REVDEPS="${FLAGS_TRUE}"
else
  SKIP_REVDEPS="${FLAGS_FALSE}"
fi

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

# Build cros_workon packages when they are changed.
CROS_WORKON_PKGS=( ${BUILD_PACKAGES_CROS_WORKON_PKGS} )

if [[ -n "${FLAGS_board_root}" ]]; then
  export ROOT="${FLAGS_board_root}"
  export PORTAGE_CONFIGROOT="${ROOT}"
  export SYSROOT="${ROOT}"
  export PKGDIR="${ROOT}"/packages
fi

# Temporarily modify the emerge flags so we can calculate the revdeps
# on the modified packages.
if [[ "${FLAGS_withrevdeps}" -eq "${FLAGS_TRUE}" &&
      "${SKIP_REVDEPS}" -eq "${FLAGS_FALSE}" ]]; then
  info "starting reverse dependency calculations ..."
  SIM_EMERGE_FLAGS=( "${EMERGE_FLAGS[@]}" --pretend --columns )

  if [[ ${#PACKAGES[@]} -gt 0 ]]; then
    SIM_EMERGE_FLAGS+=(
      --reinstall-atoms="${PACKAGES[*]}"
      --usepkg-exclude="${PACKAGES[*]}"
    )
  fi

  # cros-workon packages are always going to be force reinstalled, so we add
  # the forced reinstall behavior to the modified package calculation. This is
  # necessary to include when a user has already installed a 9999 ebuild and is
  # now reinstalling that package with additional local changes, because
  # otherwise the modified package calculation would not see that a 'new'
  # package is being installed.
  if [[ ${#CROS_WORKON_PKGS[@]} -gt 0 ]]; then
    SIM_EMERGE_FLAGS+=(
      --reinstall-atoms="${CROS_WORKON_PKGS[*]}"
      --usepkg-exclude="${CROS_WORKON_PKGS[*]}"
    )
  fi

  # Calculate only the ebuild changes from the emerge simulation ignoring
  # the virtual packages and the forced rebuild of autotest-all package.
  # The lines of the following block do the following operations:
  # 1. Do a pretend `emerge` command to get a list of what would be built.
  # 2. Filter to only packages that will be installed to the board sysroot.
  # 3. Filter to only packages that would be built from source and rewrite the
  #    line from Portage's full output to only $CATEGORY/$PACKAGE
  # 4. Filter the list of packages to a heuristic set of packages known to have
  #    incorrectly specified dependencies.
  # 5. Sort the output and remove any duplicate entries.
  BASE_INSTALL_PKGS=( $( \
    sudo -E "${EMERGE_CMD[@]}" "${SIM_EMERGE_FLAGS[@]}" "${PACKAGES[@]}" | \
    grep -e 'to /build/' | \
    sed -n -E '/^\[ebuild /{s:^[^]]+\] +::;s: .*::;p}' | \
    grep -E '/(coreboot-private-files.*|tast-build-deps)$' | \
    sort -u ) )

  MOD_PKGS=()
  if [[ "${#BASE_INSTALL_PKGS[@]}" -gt 0 ]]; then
    info "Forced rebuild packages detected: ${BASE_INSTALL_PKGS[*]}."
    # Convert specific versions into base package names
    MOD_PKGS+=( $(\
    equery-${FLAGS_board} list -p -o --format='$category/$name' \
      "${BASE_INSTALL_PKGS[@]}" | sort -u ) )
    # Remove Chrome as rebuilding it is expensive and almost never makes sense.
    # Ignore grep exit status in case chromeos-chrome is the only package.
    grep_cmd=( grep -v )
    for pkg in "${CHROME_PACKAGES[@]}"; do
      grep_cmd+=( -e "${pkg}" )
    done
    MOD_PKGS=( $(printf '%s\n' "${MOD_PKGS[@]}" | "${grep_cmd[@]}" || :) )
  fi

  FORCE_LOCAL_BUILD_PKGS+=( "${MOD_PKGS[@]}" )

  if [[ "${#MOD_PKGS[@]}" -gt 0 ]]; then
    info "calculating reverse dependencies on packages: ${MOD_PKGS[*]}"
    REV_DEPS=( $(\
      equery-${FLAGS_board} -q depends --indirect "${MOD_PKGS[@]}" |\
      awk '{print $1}' | grep -v ^virtual/ | sort -u) )
    if [[ "${#REV_DEPS[@]}" -gt 0 ]]; then
      # Convert specific versions into base package names
      RMOD_PKGS=( $(\
        equery-${FLAGS_board} -q list -p -o --format='$category/$name' \
        "${REV_DEPS[@]}" | sort -u ) )
      # Remove Chrome as rebuilding it is expensive and almost never makes
      # sense.  Ignore grep exit status in case chromeos-chrome is the only
      # package.
      grep_cmd=( grep -v )
      for pkg in "${CHROME_PACKAGES[@]}"; do
        grep_cmd+=( -e "${pkg}" )
      done
      RMOD_PKGS=( $(printf '%s\n' "${RMOD_PKGS[@]}" | "${grep_cmd[@]}" || :) )
      info "final reverse dependencies that will be rebuilt: ${RMOD_PKGS[*]}"
      FORCE_LOCAL_BUILD_PKGS+=( "${RMOD_PKGS[@]}" )
    fi
  fi
fi # end FLAGS_withrevdeps

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

echo "Builds complete"

command_completed
echo "Done"
