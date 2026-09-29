# Parallel DB-upgrade orchestrator

A headless, RAM-budgeted scheduler that runs many database upgrades concurrently on one machine,
classifies each as pass or fail, and automatically retries the ones that do not pass. It coordinates
throwaway containers across four engines (MySQL, PostgreSQL, SQL Server, Oracle), one imported
database per upgrade, and a shared search service, while staying inside a memory budget so a laptop
does not fall over.

> This is a generalized, sanitized extract of an internal tool. The engine workers (Docker
> containers, dump import, the vendor upgrade client) are specific to private data and infrastructure,
> so they are replaced here by a small mock (`lib_workers.sh`) that simulates the work. There is no
> real customer data, no credentials, and no internal references in this repository. The interesting
> part, the orchestration, is real.

## Why it exists

Validating that a batch of databases all survive a product upgrade used to mean running one upgrade
at a time, or hand-launching many by hand and babysitting them. Doing it in parallel is not just
"run them all at once": a single box has finite memory, database engines have very different resource
profiles, some engines cannot safely run two upgrades at once, and any individual upgrade can flake
for transient reasons. This orchestrator encodes those constraints so a full batch runs unattended
and lands in a clean pass/fail report.

## How it works

### RAM-budgeted admission

The scheduler computes a memory budget once at startup from the host, subtracts a reservation for the
shared search service and one per active engine, and admits a job only when its cost (heap plus
overhead) fits the remaining budget. Engine reservations are charged once and held for the run. A
`--dry-run` prints the plan as admission "waves" without starting anything, so you can see how a batch
will schedule before committing to it.

### Per-engine concurrency caps

Global concurrency is capped (default 3), and each engine has its own cap on top of that. Oracle is
hard-capped at 1 because the free engine used for validation is memory-constrained and does not
tolerate two concurrent upgrades. The caps and the budget together decide what runs when.

### Auto-retry of not-green databases

Most non-pass results in this kind of work are transient: an import race, search-service timing, a
container starved under load, or an import that silently produced an empty database. After the main
pass, every database that is not PASS (FAIL, UNKNOWN, or did-not-start) is re-run in place, serially,
while the box is now idle, up to `BATCH_RETRIES` times. A job that passes on retry flips to PASS in
the final summary; one that keeps failing is a real issue to chase. The demo shows this: the job
`customer-fail-once` fails on its first attempt and passes on the retry.

### Dump-name resolution

Real dump files are named inconsistently across machines. The catalog's dump field accepts a glob, and
a git-ignored `dumps.local` file lets each machine map a database id to its actual filename without
editing the shared catalog. A name that matches nothing is reported, and a glob that matches more than
one file is reported as ambiguous rather than guessed.

### Version-driven database sets

A bundle version selects which set of databases to validate via `release_sets.conf`, so one parameter
drives both the artifact and the set. `make_manifest.sh` builds a run manifest from the catalog,
including only entries whose dump is present, with `--only` and `--skip` to scope a run.

### Status and triage

`status_batch.sh` prints a per-database status snapshot at any time, mid-run or after (PASS, FAIL,
RUNNING, QUEUED, did-not-start), plus a one-line summary for CI. The design also includes deterministic
failure triage that fingerprints failures into a report, with no LLM or tokens involved.

## Try the demo

No Docker and no data needed. The workers are mocked, so this runs anywhere with bash.

```bash
# see the plan (nothing runs)
BATCH_RUN_TS=$(date +%Y%m%d-%H%M%S) ./batch_upgrade.sh --dry-run sample.manifest

# run the mock batch end to end (watch customer-fail-once fail, then pass on the retry)
./demo.sh

# per-database status of the most recent run
./status_batch.sh
```

## File tour

| File | Role |
|---|---|
| `batch_upgrade.sh` | The scheduler: budget, admission, concurrency, retry, summary. |
| `lib_workers.sh` | Mock engine workers for the demo (the real ones are internal). |
| `lib_diagnostics.sh` | Result classification and error-blurb extraction from an upgrade log. |
| `make_manifest.sh` | Builds a run manifest from the catalog: version sets, `--only`, `--skip`, dump resolution. |
| `status_batch.sh` | At-a-glance per-database status of a run, plus `--oneline` for CI. |
| `run_gaps.sh` | Retry the not-green databases from earlier runs. |
| `sample.manifest` | Fake catalog for the demo. |
| `release_sets.conf` | Version-to-set mapping (fake sets). |
| `dumps.local.example` | Template for per-machine dump-name overrides. |
| `demo.sh` | Runs the mock batch with demo-appropriate settings. |

## Notice

Internal working tooling. All rights reserved, no license granted.
See `NOTICE.md`.
