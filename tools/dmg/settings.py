# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

# dmgbuild settings for the release DMG (tools/release.sh); 660x400 window, icons at the background's arrow ends
import os
app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
filesystem = "HFS+"
background = defines["bg"]
window_rect = ((200, 160), (660, 400))
icon_size = 128
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
icon_locations = {os.path.basename(app): (180, 190), "Applications": (480, 190)}
