#!/bin/bash
LOG_FILE="/Users/hh/Desktop/my/launch_debug.log"
echo "Starting log monitor..." > "$LOG_FILE"
# Capture logs for kernel, amfid, launchd, runningboardd, and filtered by App ID
log stream --predicate '(process == "kernel" || process == "amfid" || process == "launchd" || process == "runningboardd" || process == "taskgated-helper")' --style syslog --debug >> "$LOG_FILE" 2>&1
