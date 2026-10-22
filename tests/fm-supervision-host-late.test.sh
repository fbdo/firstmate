#!/usr/bin/env bash
# Second half of tests/fm-supervision-host.test.sh (the cases it runs only for
# FM_SUPERVISION_HOST_PART=b), split out so each half fits the CI per-script budget.
set -u
FM_SUPERVISION_HOST_PART=b
export FM_SUPERVISION_HOST_PART
exec bash "$(dirname "${BASH_SOURCE[0]}")/fm-supervision-host.test.sh"
