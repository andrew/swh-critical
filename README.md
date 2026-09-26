# Critical package repository coverage

Ruby scripts for checking how much of the critical package repository set from packages.ecosyste.ms is present in Software Heritage. The investigation records repository snapshots and the presence of current default-branch commits using read-only requests.

Collection lists all registries through the API and requests `critical=true` packages from each. The dataset retains packages whose repository URL is missing or unusable. Package records retain their registry and original URL; repositories are deduplicated, with case-insensitive identity on GitHub and case-preserving paths elsewhere. Metadata clone URLs, HTML URLs and previous names become candidate origins, with their sources recorded.

Install the Ruby selected by `.ruby-version` and the gems in `Gemfile.lock`:

```sh
bundle install
bundle exec ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |file| require_relative file }'
```

`bundle exec ruby swh-critical.rb --help` lists the commands and options. A small pilot collects three packages per registry from three registries. Each subsequent command reads the same investigation directory:

```sh
bundle exec ruby swh-critical.rb collect --data data/pilot --registry npmjs.org --registry pypi.org --registry rubygems.org --per-page 3 --pages-per-registry 1
bundle exec ruby swh-critical.rb heads --data data/pilot --limit 9 2>&1 | tee data/pilot-heads.log
bundle exec ruby swh-critical.rb tags --data data/pilot --limit 9 2>&1 | tee data/pilot-tags.log
bundle exec ruby swh-critical.rb known --data data/pilot --limit 1000 2>&1 | tee data/pilot-known.log
bundle exec ruby swh-critical.rb origins --data data/pilot --missing-heads --limit 9 2>&1 | tee data/pilot-origins.log
bundle exec ruby swh-critical.rb report --data data/pilot
```

For a fresh collection across all registries, use `collect --data data/full` without registry or page limits. A directory holds one investigation: rerunning collection resumes its stored pagination and page size, so use a new directory for a fresh cohort. The API can change during pagination, so collection is a dated observation window rather than an atomic upstream snapshot.

Keep package collection and SWH checks in separate log files. Origin checks print UTC timestamps, a run identifier, progress against the full repository count and reasons for incomplete results. Totals appear every 25 repositories and when a batch ends or pauses. Use `tail -f data/pilot-origins.log` to watch the pilot; a finished collection log will not show subsequent SWH checks. The checked count includes unknown results, and the totals list them separately.

Check HEAD identifiers in batches before spending requests on origin history. `origins --missing-heads` selects only repositories whose observed HEAD received an explicit `known: false` result, and skips repositories whose origin coverage is already conclusive. Missing, failed or pending HEAD checks remain unresolved. Omit `--missing-heads` to check origin history independently for all repositories. Origin lookups stop at the first snapshot found across candidate URLs.

After tag lookups, `origins --missing-releases` investigates repositories with a matched tag target absent as a revision or an annotated release object confirmed missing. It skips repositories with any existing archival evidence (a snapshot, HEAD, matched release revision or annotated release object) and those with completed origin checks, and runs separately from `--missing-heads`. `report` includes the whole release-gap group in `out/release_gap_repositories.csv`, distinguishing archival evidence, no snapshot at the checked origins, and unresolved cases. Finding some archived content does not resolve the missing release objects, and a failed revision lookup does not establish the tag target's Git object type.

`origins`, `heads` and `tags` process at most 100 repositories per invocation by default; `known` checks at most 1,000 distinct identifiers. Repeat those commands to work through pending records, or set `--limit`. HTTP timeouts retry up to three times, after delays of 5, 15 and 30 seconds. Each retry logs the endpoint and delay, and discards any incomplete response body. Exhausted HTTP retries and Git errors leave checks incomplete. Inspect unknown results before repeating a large run, since unresolved records are retried first. HTTP 429 pauses the command with exit code 75 and stores a cooldown shared by commands using that directory. Rerun after the reported time; completed work remains saved.

Origin results distinguish `snapshot_found`, `no_snapshot`, `origin_not_found`, `unknown` and `unchecked`. A partial visit with a snapshot establishes some coverage, and its partial status remains in the evidence. Each run checks up to eight candidate URLs per repository and three visit pages per URL. Later runs retain conclusive observations and check untried aliases before retrying unknown results. Observations completed before a rate limit or interruption are saved. Untried aliases and incomplete visit lookups keep the result unknown unless a snapshot was found. Absence means no snapshot found at the checked URLs; other aliases or mirrors may exist.

`bundle exec ruby swh-critical.rb freshness --data data/full` compares the latest visit attempt with the latest full or partial visit carrying a snapshot, using cached pages for candidate aliases, including responses saved by later investigations, and makes no network requests. `out/freshness.json` retains visit status, alias, cache timestamp, local Git errors and incomplete lookups. Each repository has separate `current_origin` and `other_aliases` results; the top-level dates cover both. Current-origin URLs normalize to the stored repository URL, including `.git` suffixes and GitHub case variants. Other aliases may include historical URLs or mirrors. That classification does not check redirects or establish which URL is current upstream.

`out/freshness_summary.json` includes the same separation in totals, forge-host and registry groups, and the missing-HEAD comparison. Each scope has its own completeness counts and sample sizes for date statistics. A repository shared by registries appears once in each registry group; package counts include only packages in that registry with repository links.

Visit ages measure days since the visit at report time. They do not measure commit ingestion lag. Statistics use repositories with complete latest-visit lookups across their checked aliases; untried aliases remain listed separately. [SWH returns visits in descending date order](https://docs.softwareheritage.org/devel/swh-web/uri-scheme-api-origin.html), so reading stops at the first snapshot-bearing visit. Unread pages, missing cached pages and the three-page limit remain recorded. The cache timestamps define the observation window; this command does not refresh upstream observations.

HEAD checks use `git ls-remote --symref`, without a clone or checkout. Observed SHA-1 commit identifiers are stored before a separate command deduplicates them into batches of at most 1,000 for Software Heritage's `POST /api/1/known/` lookup. The client restricts requests to an allowlist of read-only endpoints. An optional `SWH_API_TOKEN` is sent only to Software Heritage; evidence files omit it.

To use a token, copy `.env.example` to `.env` in the project directory and fill in `SWH_API_TOKEN`. Commands load that file automatically, with existing environment variables taking precedence. `.env` is excluded from Git. Anonymous requests and each token have separate saved cooldowns, so a cooldown applies only to the credential that triggered it.

`tags` reads the latest release numbers saved during package collection, including from cached responses for existing investigations. It lists remote tags without cloning, and takes repositories with a confirmed missing HEAD first. It first matches package-qualified names such as `name@version`, `name-version` or `name/vversion`, then exact `version` or `vversion` names. Multiple matches remain ambiguous, and unmatched versions and missing version metadata are listed separately. These naming matches are candidates for the package release, especially for repositories containing several packages. Tag-name ordering is not used to infer publication dates.

Matched tag targets are queued as revision lookups, and annotated tag objects as release lookups. `known` deduplicates these with HEAD identifiers and processes pending HEADs first, in batches of up to 1,000 identifiers. Git ref listings do not establish the target's object type: an absent target revision is reported as `revision_not_found`, since a tag may point to a tree or file. Annotated release presence is reported separately. Compressed ref evidence is limited to 2 MiB of Git output per repository and supports `tags --offline`.

Current-commit and tag-object results describe presence anywhere in the archive. They do not establish that a repository snapshot contains a particular tag name or points to its current target. Only annotated tags have a release object. Snapshot comparison, ancestry checks, release assets and exhaustive tag history are outside these checks. Unreachable, empty and unsupported repositories remain unknown when HEAD cannot be observed.

Each directory contains SQLite records and gzip-compressed API evidence. Successful JSON responses and JSON 404s are cached for the investigation; rate limits, server failures and HTML challenge pages are refetched. Observation records retain response timestamps and cache filenames. `--offline` reads from the cache, and `report` always runs locally. A new investigation directory is required to refresh cached observations.

The default disk reserve is 5 GiB, adjustable with `--min-free-gib`. Checks run before network requests and writes. Response bodies are limited to 32 MiB, and a directory lock admits one command at a time. Oversized package pages are retried with half as many records; the retry resumes at the same position and deduplicates any overlap. The smaller page size is saved for subsequent requests and resumes. A single package exceeding the limit leaves that registry incomplete. The `clones` and `history` commands download repository objects.

`bundle exec ruby swh-critical.rb clones --data data/full --swhid /path/to/swhid` checks repositories with release gaps and no snapshot found at their checked origins. It makes one full mirror clone at a time, generates snapshot and HEAD revision SWHIDs using the supplied executable, and removes the temporary clone after processing. It records the tool version and saves compressed refs and commit IDs. The snapshot identifier is built from the tool's HEAD, branch and tag representation; an archival loader may select refs differently. Git submodules and LFS payloads are not downloaded.

Clone results are saved after each repository in `out/clone_checks.csv`. Reruns process failed checks and leave successful ones in place. Temporary clones are removed whether the command completes, errors or is interrupted. During subprocess execution the disk reserve is checked once per second, output is capped at 32 MiB, and commands time out after ten minutes. Existing checkouts under `~/code/<owner>/<repo>` or `~/code/<repo>` are flagged for review and left in place. The command computes identifiers locally and does not submit archival requests.

`bundle exec ruby swh-critical.rb clone-known --data data/full --limit 100000` checks saved snapshot and historical revision IDs through `/known/`, with snapshots first and at most 1,000 identifiers per request. Shared IDs are deduplicated and completed checks are reused. The default limit is 1,000 IDs per invocation. Results are saved in `out/clone_known.csv` and `out/clone_known_summary.json`, including when a request fails or hits a rate limit. These reports separate matched objects, unmatched checked objects and incomplete checks. They cover the history reachable in the saved clones; other snapshots, deleted refs or unreachable commits may still exist in the archive.

`bundle exec ruby swh-critical.rb history --data data/full` maps known revisions onto Git history for cloned repositories with some archived commits. It clones one repository at a time, saves parent links and commit dates, and removes the clone. Analysis uses the HEAD and revision set saved by `clones`, which fixes the baseline against new upstream commits. The CSV and JSON reports in `out/history_coverage.*` show the first-parent coverage pattern, the nearest archived first-parent ancestor, and archived commits outside HEAD's ancestry. They also count missing parents of archived commits. Dates are Git committer dates, not archival visit dates; a continuous older history is consistent with a stale capture but does not identify which origin supplied it. Cached graphs can be analyzed with `--offline`.

`bundle exec ruby swh-critical.rb origin-search --data data/full` searches for the saved clone URLs using SWH's case-insensitive origin search. It checks visits for matching repository URLs and `pkg.go.dev` references, while keeping other substring matches separate. Results are saved in `out/origin_search.json`. A package-registry snapshot can preserve extracted source contents without preserving Git history; its presence alone does not explain a matching Git revision.

`bundle exec ruby swh-critical.rb trace --data data/full --repositories repositories.txt` compares snapshot revision targets with saved history for repository URLs listed one per line. It searches one page of up to 1,000 origins and checks at most 12 candidates per repository, recorded aliases first. The report in `out/origin_traces.json` identifies shared commits and exact matches for the newest archived first-parent ancestor. These matches establish shared history without identifying its first ingestion source. Candidate limits and incomplete snapshot pagination are recorded; an unsuccessful search does not establish absence elsewhere in the archive.

`bundle exec ruby swh-critical.rb package-contents --data data/full --swhid /path/to/swhid` compares package snapshots with Git trees for cloned repositories whose saved revisions were all absent from SWH. It processes one temporary mirror clone at a time and removes it after saving tree IDs. For matching package origins it checks up to 50 release targets, prioritizing snapshot HEAD, and follows up to six single-directory wrappers. Exact matches establish source-tree coverage even when Git revisions are absent. A mismatch can come from package filtering or file modes, so the files may still be present. Results are saved in `out/package_contents.json`; cached tree evidence supports `--offline`.

For selected repositories, save their URLs one per line in `repositories.txt` and run:

```sh
bundle exec ruby swh-critical.rb origin-candidates --data data/full --repositories repositories.txt
bundle exec ruby swh-critical.rb contents --data data/full --repositories repositories.txt --swhid /path/to/swhid
bundle exec ruby swh-critical.rb origin-contents --data data/full --repositories repositories.txt
```

`origin-candidates` searches repository names, recorded former names and cohort package names. It saves up to three search pages per pattern in `out/origin_candidates.json`. Results are candidates for investigation; name matches do not establish repository identity or change origin coverage.

`contents` requires a completed `clones` baseline. It clones one repository at a time, saves directory and file-content IDs reachable from the saved HEAD, generates fresh snapshot and revision SWHIDs, and removes the clone. New upstream commits and history outside that HEAD's ancestry are excluded from content counts. Shared IDs are deduplicated and checked through `/known/` in batches of up to 1,000. `out/content_coverage.json` reports historical objects, exact root-tree matches and each saved HEAD file's result. Common files can occur in unrelated projects; their presence alone does not establish that a repository was archived. Submodule repositories and LFS payloads are not fetched. Cached evidence supports offline reruns.

`origin-contents` uses that saved content evidence to compare native CRAN, Hackage and npm package snapshots. It prioritizes the collected package version and snapshot HEAD, inspecting at most three distinct targets per package and 100 directory listings per target. It follows both release and revision targets, and records exact Git root-tree matches separately from matching file contents in `out/origin_contents.json`. Limits and incomplete walks are recorded. File matches ignore paths and modes; files missing from these selected snapshots may exist elsewhere. Neither command downloads archived file bodies to verify their availability.

To recover a published package from its archived source, start with its registry and name in a separate investigation directory:

```sh
bundle exec ruby swh-critical.rb restore --data data/recovery-demo --registry npmjs.org --package possible-typed-array-names
```

`restore` reads package and version metadata from ecosyste.ms, derives the native npm, CRAN or Hackage origin, and follows the selected version's snapshot branch to its source directory. It defaults to the latest version in ecosyste.ms; use `--package-version` to select another. It downloads file bodies from SWH, verifies content hashes and the reconstructed directory hash, then publishes the files under `restored/`. The evidence manifest is `out/recovery.json`. This needs no repository clone, registry tarball or supplied SWHID. It recovers the extracted package files; Git history, omitted repository files, dependencies and the original tarball bytes remain outside that result. Recovery writes the files to disk and stops there.

Recovery is capped at 100 MiB of file contents, 10,000 files, 1,000 directories and 32 directory levels, with the same disk reserve and response limits as other commands. Unsupported entries and symlinks escaping the restored directory are rejected. Partial output is removed on failure, while cached responses support resuming and `--offline` replay. An existing `restored/` directory must match the expected tree; use a new investigation directory for another package or version.

`bundle exec ruby swh-critical.rb extrinsic-metadata --data data/full --targets targets.txt` reads core SWHIDs, one per line, and queries their metadata authorities, records and payloads using GET requests. `out/extrinsic_metadata.json` retains authority, format, fetcher, discovery date, object context and cached evidence. The report includes JSON payloads inline and keeps other payloads base64-encoded in the cache. Each payload has a byte count and SHA-256 checksum. The command does not submit metadata or change object coverage.

Each run processes up to 100 pending targets by default, with `--limit` to change that count. Per target, it checks up to ten authorities and three pages of ten records per authority. Results stay incomplete when a limit is hit, a request fails or a payload is missing. Rerunning resumes through the cache, and `--offline` reads from it exclusively. A successful empty authority list describes only the requested object, and does not establish that the object or its package links are absent elsewhere. The [SWH metadata API](https://docs.softwareheritage.org/devel/apidoc/swh.web.api.views.metadata.html) documents the authority and record lookup endpoints.

`report` writes `out/summary.json`, `out/repositories.csv`, `out/packages.csv`, `out/registries.csv` and `out/release_tags.csv`. The summary includes incomplete registry scans and packages without repositories, and separates repository counts from distinct object counts. Tag matching and coverage counts are per package; shared objects are queried once. `missing_heads_repository_coverage` reports origin coverage just for repositories whose current commit is missing. A present commit does not change the separate origin coverage result. Follow-up history and content reports remain separate from this summary. The pilot is an alphabetical sample; cohort-wide coverage comes from a full collection. Raw data and generated reports are excluded from Git.

Recover missing links with `bundle exec ruby swh-critical.rb recover --data data/full --mappings data/full/recoveries.csv`. The CSV needs `registry,purl,repository_url,evidence_url,evidence_file,reason` columns. Verify each link against upstream package metadata first; cached repository metadata can refer to an unrelated project. Evidence files must be saved inside the investigation directory, with paths relative to it. Recovery fills missing links, retains the original values and records the evidence file's SHA-256. It rejects conflicting mappings and can be rerun. Run `heads` and `known` again to check newly added repositories. Reports include the recovery count and a `repository_recoveries.csv` evidence export.

Collect science metadata in a separate directory so it can run alongside the coverage scan:

```sh
bundle exec ruby swh-critical.rb science --data data/science --per-page 1000 --limit 1
bundle exec ruby swh-critical.rb science-report --data data/science --cohort data/full
bundle exec ruby swh-critical.rb science --data data/science --per-page 1000
```

`science` reads the science service's `projects/search_seeds` and `packages` endpoints. `--limit` caps pages per source for a pilot; omit it to finish both lists. Project pages are capped at 100 records and package pages at 1,000. Pagination resumes from the last saved page, with the same disk reserve, response limits, evidence cache and rate-limit handling as the coverage checks. Collections are dated observation windows over live data, and a new directory refreshes them.

`science-report` reads a consistent snapshot of the cohort database without taking its command lock or changing it. It writes `out/science_summary.json`, `out/science_packages.csv` and `out/science_matches.csv` in the science directory, and can be run again as either collection progresses. Project matches use versionless PURLs, normalized repository URLs and recorded previous repository names. Scientific dependency matches require a PURL match; a shared monorepo alone does not establish that a particular package is used by research software. Match methods and source evidence are retained in the CSV.

The two science groups overlap because they come from different filters. Projects come from the service's visible scientific project selection, currently a science score of at least 20. Dependencies come from its direct scientific-use listing, which applies its own repository science-score filter. Unmatched records remain `not_matched_yet` until both lists finish, then `not_matched`; neither means the package is unrelated to research. A repository is unmatched only when none of its cohort packages match, although individual packages within a matched monorepo can remain unmatched. Coverage counts use distinct repository URLs; release checks are per package. All coverage figures here come from this investigation's own observations rather than the science API's aggregate SWH statistics.

Licensed under the [MIT License](LICENSE).
