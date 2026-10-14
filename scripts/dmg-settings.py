# dmgbuild settings for Pretty Studio's drag-to-Applications disk image.
# Driven by scripts/make-dmg.sh:  dmgbuild -s scripts/dmg-settings.py -D app=... -D background=... -D icon=... "Pretty Studio" out.dmg
import os.path

application = defines["app"]
appname = os.path.basename(application)

format = "ULFO"          # lzfse-compressed, read-only
filesystem = "HFS+"
size = None
files = [application]
symlinks = {"Applications": "/Applications"}
icon = defines.get("icon")
hide_extensions = [appname]

background = defines["background"]   # TIFF holding 1x + 2x
window_rect = ((200, 140), (660, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = "auto"

icon_size = 128
text_size = 13
label_pos = "bottom"
arrange_by = None
grid_spacing = 100
icon_locations = {
    appname: (170, 196),
    "Applications": (490, 196),
}
