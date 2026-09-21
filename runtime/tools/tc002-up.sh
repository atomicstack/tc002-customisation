#!/usr/bin/env bash
# tc002-up.sh: the old name for an in-place update. everything is in tc002-update.sh now, which
# also does the other kind of update, the one that reboots:
#
#   runtime/tools/tc002-update.sh --in-place ...   no reboot; gone on the next power cycle (this)
#   runtime/tools/tc002-update.sh --flash ...      reboots; permanent
#
# the options are the same as they were: --device, --tz, --ntp, --font, --base, --no-build,
# --keep-settings, --reset-settings.
exec "$(cd "$(dirname "$0")" && pwd)/tc002-update.sh" --in-place "$@"
