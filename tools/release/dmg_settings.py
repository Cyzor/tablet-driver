# dmgbuild settings for the MockTab installer DMG.
# Invoked by release.sh via: dmgbuild -s dmg_settings.py -D app=<path> "MockTab <ver>" <dmg-path>
#
# Install: pip3 install dmgbuild

import os

application = defines.get("app")
appname = os.path.basename(application)

# Background image lives alongside this settings file. Not designed yet
# ([[project_dmg_installer_view_customization]]) -- falls back to a plain
# background until dmg_background.png is added here.
_background_path = os.path.join(os.path.dirname(__file__), "dmg_background.png")
if os.path.exists(_background_path):
    background = _background_path

format = "UDZO"
filesystem = "HFS+"

files = [application]
symlinks = {"Applications": "/Applications"}

window_rect = ((100, 100), (589, 435))
icon_size = 120
icon_locations = {
    appname: (150, 200),
    "Applications": (439, 200),
}

default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
