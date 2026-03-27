#!/bin/bash
# Wrapper script for xdg-desktop-portal-termfilechooser
#
# Portal passes 6 arguments:
#   $1 - multiple: "1" = multi-select allowed, "0" = single file
#   $2 - directory: "1" = selecting directories only, "0" = files allowed
#   $3 - save: "0" = open mode, "1" = save mode
#   $4 - path: suggested path/filename for save dialogs
#   $5 - out: output file to write selected paths (one per line)
#   $6 - debug: "1" = debug mode enabled
#
# Configuration:
#   TERMINAL or TERMCMD: Terminal emulator command (default: foot)
#   SAP_PICKER_DEBUG: Set to "1" to enable debug logging
#
# Installation:
#   1. Copy this script to ~/.config/xdg-desktop-portal-termfilechooser/
#   2. Make it executable: chmod +x sap-picker.sh
#   3. Configure portal config:
#      ~/.config/xdg-desktop-portal-termfilechooser/config:
#      [filechooser]
#      cmd=sap-picker.sh
#      default_dir=$HOME

set -e

MULTIPLE="$1"
DIRECTORY="$2"
SAVE="$3"
PATH_HINT="$4"
OUTPUT="$5"
DEBUG="$6"

# Debug logging
log_debug() {
    if [[ "$DEBUG" == "1" ]] || [[ "$SAP_PICKER_DEBUG" == "1" ]]; then
        echo "[sap-picker] $*" >> /tmp/sap-picker.log
    fi
}

log_debug "Args: multiple=$MULTIPLE directory=$DIRECTORY save=$SAVE path=$PATH_HINT output=$OUTPUT"

# Determine mode
if [[ "$SAVE" == "1" ]]; then
    MODE="save"
elif [[ "$DIRECTORY" == "1" ]]; then
    MODE="open_dir"
else
    MODE="open"
fi

# Build nvim lua command (bypasses lazy loading, enable restricted mode)
PICKER_OPTS="mode='$MODE', output_file='$OUTPUT', quit_on_confirm=true"
[[ "$MULTIPLE" == "1" ]] && PICKER_OPTS="$PICKER_OPTS, multiple=true"
[[ -n "$PATH_HINT" ]] && PICKER_OPTS="$PICKER_OPTS, initial_path='$PATH_HINT'"
NVIM_CMD="lua require('sap.standalone').enable(); require('sap.picker').open({$PICKER_OPTS})"

log_debug "Command: $NVIM_CMD"

# Determine starting directory
if [[ -n "$PATH_HINT" ]]; then
    START_DIR=$(dirname "$PATH_HINT")
else
    START_DIR="$HOME"
fi

# Determine terminal
TERM_CMD="${TERMINAL:-${TERMCMD:-foot}}"

log_debug "Terminal: $TERM_CMD, Start dir: $START_DIR"

# Launch neovim with picker
# Note: Different terminals have different argument syntax
case "$TERM_CMD" in
    *kitty*)
        exec $TERM_CMD -o confirm_os_window_close=0 --app-id sap-picker --directory "$START_DIR" nvim -c "$NVIM_CMD"
        ;;
    *alacritty*)
        exec $TERM_CMD --class sap-picker --working-directory "$START_DIR" -e nvim -c "$NVIM_CMD"
        ;;
    *wezterm*)
        exec $TERM_CMD start --class sap-picker --cwd "$START_DIR" -- nvim -c "$NVIM_CMD"
        ;;
    *foot*)
        exec $TERM_CMD --app-id sap-picker --working-directory="$START_DIR" nvim -c "$NVIM_CMD"
        ;;
    *)
        # Generic fallback - try -e flag
        cd "$START_DIR"
        exec $TERM_CMD -e nvim -c "$NVIM_CMD"
        ;;
esac
