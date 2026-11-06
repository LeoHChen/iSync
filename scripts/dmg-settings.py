# Layout for the iSync disk image. Used by dmgbuild from scripts/make-release.sh.
import os.path

application = defines["app"]
app_name = os.path.basename(application)

format = "UDZO"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(application, "Contents/Resources/AppIcon.icns")

window_rect = ((200, 200), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
background = "builtin-arrow"
icon_size = 128
text_size = 14
icon_locations = {app_name: (160, 190), "Applications": (480, 190)}
