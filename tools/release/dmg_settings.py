# dmgbuild settings for the MockTab installer DMG.
# Invoked by release.sh via: dmgbuild -s dmg_settings.py -D app=<path> -D background=<png> "MockTab <ver>" <dmg-path>
#
# Install: pip3 install dmgbuild

import os

application = defines.get("app")
appname = os.path.basename(application)

# dmgbuild pairs dmg_background.png with its @2x sibling into a Retina TIFF.
background = defines.get("background")

format = "UDZO"
filesystem = "HFS+"

files = [application]
symlinks = {"Applications": "/Applications"}

# 700×500 pt: the art plus a 40 pt strip for a path bar, if the user shows one.
window_rect = ((200, 200), (700, 500))
icon_size = 128
text_size = 12
icon_locations = {
    appname: (133, 251),
    "Applications": (542, 251),
}

default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
