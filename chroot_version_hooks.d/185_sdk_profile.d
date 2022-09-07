# Copyright 2021 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

sudo rm -f "/etc/profile.d/chromiumos-niceties.sh"
sudo ln -sfT \
  "/mnt/host/source/chromite/sdk/etc/profile.d/50-chromiumos-niceties.sh" \
  "/etc/profile.d/50-chromiumos-niceties.sh"
