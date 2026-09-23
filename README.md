# Critical package repository coverage

Ruby scripts for checking how much of the critical package repository set from packages.ecosyste.ms is present in Software Heritage. The investigation records repository snapshots and the presence of current default-branch commits, with no archival submissions.

Collection discovers all registries through the API and requests `critical=true` packages from each. Packages without a usable repository URL remain in the dataset. Package records retain their registry and original URL; repositories are deduplicated, with case-insensitive identity on GitHub and case-preserving paths elsewhere. Metadata clone URLs, HTML URLs and previous names become candidate origins, with their sources recorded.

Install the Ruby selected by `.ruby-version` and the gems in `Gemfile.lock`:

```sh
bundle install
bundle exec ruby -Itest test/cli_test.rb
```

A small pilot collects three packages per registry from three registries. Each subsequent command reads the same investigation directory:

```sh
bundle exec ruby swh-critical.rb collect --data data/pilot --registry npmjs.org --registry pypi.org --registry rubygems.org --per-page 3 --pages-per-registry 1
bundle exec ruby swh-critical.rb heads --data data/pilot --limit 9 2>&1 | tee data/pilot-heads.log
bundle exec ruby swh-critical.rb known --data data/pilot --limit 1000 2>&1 | tee data/pilot-known.log
bundle exec ruby swh-critical.rb origins --data data/pilot --missing-heads --limit 9 2>&1 | tee data/pilot-origins.log
bundle exec ruby swh-critical.rb report --data data/pilot
```

For a fresh collection across all registries, use `collect --data data/full` without registry or page limits. A directory holds one investigation: rerunning collection resumes its stored pagination and page size. Use a new directory for a fresh cohort. The API can change during pagination, so collection is a dated observation window rather than an atomic upstream snapshot.

Keep package collection and SWH checks in separate log files. Origin checks print UTC timestamps, a run identifier, progress against the full repository count and reasons for incomplete results. Totals appear every 25 repositories and when a batch ends or pauses. Use `tail -f data/pilot-origins.log` to watch the pilot; a finished collection log will not show subsequent SWH checks. The checked count includes unknown results, which remain separate in the totals.

Check HEAD identifiers in batches before spending requests on origin history. `origins --missing-heads` selects only repositories whose observed HEAD received an explicit `known: false` result, and skips repositories whose origin coverage is already conclusive. Missing, failed or pending HEAD checks remain unresolved. Omit `--missing-heads` to check origin history independently for all repositories. Origin lookups stop at the first snapshot found across candidate URLs.

`origins` and `heads` process at most 100 repositories per invocation by default; `known` checks at most 1,000 distinct identifiers. Repeat those commands to work through pending records, or set `--limit`. HTTP and Git errors leave checks incomplete. Inspect unknown results before repeating a large run, since unresolved records are retried first. HTTP 429 pauses the command with exit code 75 and stores a cooldown shared by commands using that directory. Rerun after the reported time; completed work remains saved.

Origin results distinguish `snapshot_found`, `no_snapshot`, `origin_not_found`, `unknown` and `unchecked`. A partial visit with a snapshot establishes some coverage, and its partial status remains in the evidence. Checks inspect up to eight candidate URLs and three visit pages per URL. Exhausted limits remain unknown unless a snapshot was found. Absence means no snapshot found at the checked URLs; other aliases or mirrors may exist.

HEAD checks use `git ls-remote --symref`, without a clone or checkout. Observed SHA-1 commit identifiers are stored before a separate command deduplicates them into batches of at most 1,000 for Software Heritage's `POST /api/1/known/` lookup. The client has an endpoint allowlist and no archival submission operation. An optional `SWH_API_TOKEN` is sent only to Software Heritage and is not stored in evidence.

To use a token, copy `.env.example` to `.env` in the project directory and fill in `SWH_API_TOKEN`. Commands load that file automatically, with existing environment variables taking precedence. `.env` is excluded from Git. Anonymous requests and each token have separate saved cooldowns; adding a token does not inherit an anonymous cooldown.

Current-commit results describe presence anywhere in the archive. They do not establish that the repository's latest snapshot points to that commit, or how many commits behind it is. Snapshot comparison, ancestry checks and tags/releases are further investigation stages. Unreachable, empty and unsupported repositories remain unknown when HEAD cannot be observed.

Each directory contains SQLite records and gzip-compressed API evidence. Successful JSON responses and JSON 404s are cached for the investigation; errors such as rate limits, server failures and HTML challenge pages are not cached. Observation records retain response timestamps and cache filenames. `--offline` supports cached HTTP reads, while `report` always works locally. A new investigation directory is required to refresh cached observations.

The default disk reserve is 5 GiB, adjustable with `--min-free-gib`. Checks run before network requests and writes, response bodies are limited to 32 MiB, and one command at a time may use a given directory. Oversized package pages are retried with half as many records, preserving the position without skipping records and deduplicating any overlap. The smaller page size is saved for subsequent requests and resumes. A single package exceeding the limit leaves that registry incomplete. No repository clones are created by the current commands.

`report` writes `out/summary.json`, `out/repositories.csv`, `out/packages.csv` and `out/registries.csv`. The summary includes incomplete registry scans and packages without repositories, and separates repository counts from distinct commit counts. `missing_heads_repository_coverage` reports origin coverage just for repositories whose current commit is missing. A present commit does not change the separate origin coverage result. The pilot is an alphabetical sample and cannot estimate coverage across the full cohort. Raw data and generated reports are excluded from Git.

Licensed under the [MIT License](LICENSE).
