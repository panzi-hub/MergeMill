# Supported platform

macOS is the only supported host for this version.

The dispatcher clock and the lane-GC timer are launchd user agents. `install-dispatcher-timer.sh` and `install-gc-timer.sh` refuse every other operating system. Do not add a cron, systemd, or OpenClaw fallback to keep another host working.

`install-dispatcher-timer.sh` sets `AbandonProcessGroup`. A finished tick must not kill the dev and review wrappers it just spawned. Reinstalling a plist without that key restores the kill.

A later version may adapt the same pipeline to another operating system. That adaptation is a new release, not a second path maintained in this tree.

GitHub-hosted Ubuntu jobs only execute hermetic shell tests. They are not a supported deployment target.
