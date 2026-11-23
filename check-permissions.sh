#!/bin/bash
# Prints the installed app's Microphone / Speech Recognition permission state
# without prompting. Launched through LaunchServices so macOS checks the app's
# own identity (running the binary from a shell would check the shell's).
OUT=$(mktemp)
open -n -W --stdout "$OUT" 2>/dev/null /Applications/Teleprompter.app --args --permission-status
cat "$OUT"; rm -f "$OUT"
