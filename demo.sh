#!/usr/bin/env bash
# demo.sh — run the mock end-to-end demo. No Docker, no network, no real data.
#
# The workers are mocked (see lib_workers.sh), so jobs consume no real RAM or CPU. We therefore turn
# off the real-available-RAM cap (BATCH_RAM_REALCAP=0) so the schedule follows the modeled budget
# instead of whatever this laptop happens to have free, and we turn off the Docker-based hygiene and
# spin-down steps (there are no containers). BATCH_RETRIES=1 exercises the auto-retry cycle: the
# job "customer-fail-once" fails on its first attempt and passes on the retry.
set -uo pipefail
cd "$(dirname "$0")"
export BATCH_RUN_TS="${BATCH_RUN_TS:-$(date +%Y%m%d-%H%M%S)}"
export BATCH_RAM_REALCAP=0 BATCH_HYGIENE=0 BATCH_SPINDOWN=0 BATCH_DISCOVER=0
export BATCH_RETRIES="${BATCH_RETRIES:-1}"
export BATCH_MAX_CONCURRENCY="${BATCH_MAX_CONCURRENCY:-3}"
exec ./batch_upgrade.sh "${1:-sample.manifest}"
