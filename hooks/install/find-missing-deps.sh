#!/bin/bash
# Copyright 2023 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Generate an error if a cros-workon-ed ebuild has missing dependencies.

# Set ebuild vars to make shellcheck happy.
: "${PV:=}" "${SYSROOT:=/}" "${T:=}"

if [[ "${PV}" == "9999" ]]; then
  args=()
  if [[ "${SYSROOT}" == "/build/"* ]]; then
    args+=( "--board=${SYSROOT##*/}" )
  fi
  args+=( --match --build-info="${T}/../build-info/" )
  einfo "Checking dependencies: ${args[*]}"
  /mnt/host/source/chromite/scripts/package_has_missing_deps \
    "${args[@]}" || die 'found missing dependencies'
fi
