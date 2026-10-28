#!/bin/sh
# Subscribe to "*" to build a local activity feed from newline-delimited JSON.
# Read the payload as data; never eval it or interpolate it into a command.
set -eu
event_log_dir="${HOME}/Library/Logs/Workbench"
mkdir -p "$event_log_dir"
cat >> "$event_log_dir/events.jsonl"
