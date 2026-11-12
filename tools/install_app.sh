#!/bin/sh
# Install okorec for the current user: binary, launcher and global shortcuts.
#   install_app.sh <prefix> <okorec binary>
# The privileged helper (okorec-kms) is deliberately not touched: replacing the
# file would drop its capability. Install it once by hand:
#   cp zig-out/bin/okorec-kms ~/.local/bin/ && pkexec setcap cap_sys_admin+ep ~/.local/bin/okorec-kms
set -eu
prefix=$1
bin=$2

mkdir -p "$prefix/bin" "$prefix/share/applications"
# Replace atomically so a running instance keeps its old file.
cp "$bin" "$prefix/bin/okorec.new" && mv "$prefix/bin/okorec.new" "$prefix/bin/okorec"

cat > "$prefix/share/applications/okorec.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=OkoRec
Comment=Screen recorder with instant replay
Exec=$prefix/bin/okorec
Icon=media-record
Terminal=false
Categories=AudioVideo;Recorder;
DESKTOP

# GNOME custom shortcuts (work in fullscreen games too). Idempotent.
command -v gsettings >/dev/null 2>&1 || { echo "installed (no gsettings: shortcuts skipped)"; exit 0; }
schema=org.gnome.settings-daemon.plugins.media-keys
base=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
list=$(gsettings get $schema custom-keybindings)
add() { # id name binding command
    path="$base/$1/"
    gsettings set "$schema.custom-keybinding:$path" name "$2"
    gsettings set "$schema.custom-keybinding:$path" binding "$3"
    gsettings set "$schema.custom-keybinding:$path" command "$4"
    case "$list" in
        *"'$path'"*) ;;
        "@as []"|"[]") list="['$path']" ;;
        *) list="${list%]}, '$path']" ;;
    esac
}
add okorec-save "okorec: save replay" "<Super>F10" "$prefix/bin/okorec save"
add okorec-record "okorec: start/stop recording" "<Super>F9" "$prefix/bin/okorec record"
gsettings set $schema custom-keybindings "$list"
echo "installed $prefix/bin/okorec, launcher, shortcuts Super+F10 (save replay) and Super+F9 (record)"
