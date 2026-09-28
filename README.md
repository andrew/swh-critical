# Critical package coverage in Software Heritage

This investigation checks how much of the critical package set from packages.ecosyste.ms is preserved in Software Heritage (SWH). It compares current Git commits and release tags with archived objects, then follows gaps through repository history and package source trees. The Ruby scripts make read-only archive requests and retain evidence for each check.

## Executive summary

The September 2026 investigation covered 9,823 critical, highly used open source packages and 6,984 linked repositories. It found some archived material for most projects, with gaps in current commits and release identifiers. Finding that material required searches beyond current repository URLs, including checks of older Git history and comparisons with packaged source files.

ecosyste.ms metadata supplied the repository links and package versions needed to locate snapshots and check their connection to a project or its published packages. Some associations remained weak even after comparing archived source with Git trees and files. For example, an exact source-tree match for `is-data-view` established a connection to its Git repository, but equivalence to its published npm package remained unverified.

The observed default-branch commit was missing for 1,817 repositories, although 1,728 of those had a snapshot at a checked URL. Follow-up history checks found older captures followed by missing newer commits, consistent with archival lag. In one recovery, all published package files were retrieved even though the Git revision recorded in its metadata was absent.

All 46 repositories left unresolved by the initial release-gap checks eventually yielded some archived history or source content. Their current-commit and release-object gaps remained, and these partial matches did not establish that their latest releases or full histories could be recovered.

- [Findings](#findings)
- [What the checks measure](#what-the-checks-measure)
- [Running the scripts](#running-the-scripts)
- [Data and reports](#data-and-reports)
- [License](#license)

## Findings

Collection and archive checks ran on 23 and 24 September 2026, with separate cutoffs for each report. None of the collected investigation data is committed to this repository. The figures are included here, but the report paths below refer to local files that are absent from a fresh clone.

### Current commits and repository snapshots

Collection completed scans of 110 registries and retained 9,823 packages, including those without usable repository links. Verified link recovery added 254 mappings, leaving 543 packages without a repository. Repository totals deduplicate packages that share the same repository.

| Observed default-branch commit | Repositories |
| --- | ---: |
| Present in SWH | 4,979 |
| Missing from SWH | 1,817 |
| Unknown | 132 |
| Unchecked | 56 |
| Total | 6,984 |

Of the 1,817 repositories with a missing current commit, 1,728 had a snapshot at a checked origin. Nine had visits without a snapshot, and 80 had no origin at the checked URLs. Those last two groups may still have content under other URLs or package origins. The cohort report is dated 24 September at 10:26:24 UTC (`data/full/out/summary.json`).

### Latest releases

Tag names matched the collected latest version for 6,958 packages. Their target revisions were present for 6,252 and not found for 706; among matched annotated tags, 3,108 release objects were present and 373 were missing. These are package counts, so a shared object can contribute to more than one package's result. A tag target absent as a revision may instead be a tree or file.

Another 2,025 packages had no matching tag, 12 had ambiguous matches and 241 had unknown results. The remaining packages lacked a repository link (543) or version (44). A separate Go audit resolved 84 pseudo-versions among 132 unmatched Go versions to full commit hashes with matching timestamps: 82 revisions were present and two were missing. This later check did not change the original tag-match totals; the other 48 unmatched Go versions were outside its scope.

Release counts are in `data/full/out/summary.json` and `release_tags.csv` in the same output directory. The Go results are in `data/analysis/final-20260924/go-pseudo-versions.json`, with archive checks dated 24 September at 15:26:20 UTC.

### Following the release gaps

Missing release objects or tag target revisions affected 534 repositories. Initial checks found some archival evidence for 488, leaving 46 with no snapshot at the checked URLs and no matching HEAD or tag objects. Full clones of those 46 supplied 24,124 distinct historical revision IDs: 16,780 were present in SWH across 36 repositories, and 7,344 were missing.

All 36 had continuous older first-parent history followed by a missing tip. The missing tip ranged from 5 to 384 first-parent commits, with a median of 24. That pattern is consistent with an older capture, although Git committer dates do not establish when the objects entered SWH or which origin supplied them.

The ten repositories without matching Git revisions still had archived source content. Four had exact older Git root-tree matches in package snapshots found through `pkg.go.dev`; five more had older root trees present in the archive. The remaining repository, `bare-events`, had matching files and subdirectories but no root-tree match in the checked ancestry. All 534 release-gap repositories therefore had some archival evidence after follow-up, while their observed HEAD and release-object gaps remained.

These follow-ups concern a selected group of 46 repositories and do not estimate coverage across the whole cohort. Their evidence is in `data/full/out/clone_known_summary.json`, `history_coverage.json`, `package_contents.json`, `content_coverage.json` and `origin_contents.json`.

### Verifying project and package links

Package metadata from ecosyste.ms linked registry names and versions to repositories, including former repository names. These links guided searches for candidate snapshots. To check the associations, the investigation compared archived release branches with package versions and computed Git tree and file-content identifiers for comparison with SWH objects.

For `is-data-view`, a snapshot found through `pkg.go.dev` contained an exact Git root-tree match, but its equivalence to the published npm artifact was not verified. `bare-events` had matching file contents without an exact Git root-tree match in the checked ancestry; those comparisons ignored paths and modes, and the file bodies were not retrieved. Shared files can occur in unrelated projects, so file matches alone cannot confirm project identity.

The `possible-typed-array-names` recovery below went further by retrieving and hash-verifying files from a native npm snapshot. It still did not verify the original package archive bytes or signatures. `data/analysis/final-20260924/package-swh-examples.json` records the evidence and remaining gaps for all three examples.

### Visit ages

Among missing-HEAD repositories, the median age of the latest visit attempt was 15.89 days across 1,735 repositories. The latest snapshot-bearing visit had a median age of 23.24 days across 1,728, and 729 repositories had an attempt newer than their latest snapshot. These ages are measured at the freshness report's cutoff, 24 September at 12:57:39 UTC.

Aliases matching the stored repository URL had snapshot-bearing visits for 1,490 repositories, with a median age of 21.80 days. Other aliases had them for 254 repositories, with a median age of 420.82 days; the groups overlap. Only 185 of the 1,817 repositories had every candidate alias checked. Visit ages describe archive activity and cannot establish commit ingestion lag.

`data/analysis/final-20260924/freshness-summary.json` includes later cached observations and separates current-origin aliases from historical URLs or mirrors. The earlier `data/full/out/freshness_summary.json` has a different cutoff.

### Scientific packages

The science service's project and dependency listings matched a union of 1,020 critical packages and 732 repositories. At this comparison's earlier cutoff, 24 September at 08:46:46 UTC, missing HEADs among resolved checks were 122/367 (33.2%) for scientific projects, 223/689 (32.4%) for scientific dependencies and 1,577/6,076 (26.0%) for unmatched repositories.

Matched tag targets were absent as revisions for 6.6% of scientific project packages, 9.2% of dependency packages and 10.4% of unmatched packages with matched tags. The scientific groups overlap and have different registry mixes, so these unadjusted comparisons do not isolate an effect of scientific use. Packages absent from the listings may still be used in research.

`data/analysis/final-20260924/science-comparison.json` retains the denominators and matching evidence. Its origin-coverage counts retain the earlier cutoff and exclude the later cohort origin checks.

### Recovering package files

A separate recovery started with the npm package name `possible-typed-array-names` and restored its published version `1.1.0` through a native package origin. Although the Git revision in the package metadata was absent from SWH, all ten published files were retrieved, totalling 9,698 bytes. File hashes and the reconstructed directory hash were verified; this recovered extracted package files, without establishing preservation of Git history or the original tarball bytes.

The recovery manifest is `data/recovery-demo/out/recovery.json`. A separate sample of 15 objects found eight extrinsic metadata records on three directories and empty authority lists on the other 12 objects (`data/full/out/extrinsic_metadata.json`). Those empty results apply only to the requested objects and do not establish that package metadata is absent elsewhere.

## What the checks measure

| Evidence | What a match establishes |
| --- | --- |
| Origin visit with a snapshot | Some coverage at the checked source URL |
| Revision | Presence of the checked Git commit somewhere in the archive |
| Release object | Presence of an annotated Git tag; lightweight tags have no separate release object |
| Directory or content object | Presence of a source tree or file, which may have been archived without the corresponding Git revision |

HEAD and tag-object lookups do not establish whether a snapshot preserves a tag name or points to its current target. They do not traverse ancestry or check release assets and exhaustive tag history. Unreachable, empty and unsupported repositories remain unknown when HEAD cannot be observed.

## Running the scripts

All commands run through `swh-critical.rb` from the repository root. Start with a pilot in a new investigation directory; the later history and content commands follow up selected gaps.

### Installation and authentication

Install the Ruby selected by `.ruby-version` and the gems in `Gemfile.lock`:

```sh
bundle install
bundle exec ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |file| require_relative file }'
```

To use a token, copy `.env.example` to `.env` in the project directory and fill in `SWH_API_TOKEN`. Commands load that file automatically, with existing environment variables taking precedence. `.env` is excluded from Git. Anonymous requests and each token have separate saved cooldowns, so a cooldown applies only to the credential that triggered it.

### Collecting a cohort and running a pilot

Collection lists all registries through the API and requests `critical=true` packages from each. The dataset retains packages whose repository URL is missing or unusable. Package records retain their registry and original URL; repositories are deduplicated, with case-insensitive identity on GitHub and case-preserving paths elsewhere. Metadata clone URLs, HTML URLs and previous names become candidate origins, with their sources recorded.

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

### Batches, logs and retries

Keep package collection and SWH checks in separate log files. Origin checks print UTC timestamps, a run identifier, progress against the full repository count and reasons for incomplete results. Totals appear every 25 repositories and when a batch ends or pauses. Use `tail -f data/pilot-origins.log` to watch the pilot; a finished collection log will not show subsequent SWH checks. The checked count includes unknown results, and the totals list them separately.

`origins`, `heads` and `tags` process at most 100 repositories per invocation by default; `known` checks at most 1,000 distinct identifiers. Repeat those commands to work through pending records, or set `--limit`. HTTP timeouts retry up to three times, after delays of 5, 15 and 30 seconds. Each retry logs the endpoint and delay, and discards any incomplete response body. Exhausted HTTP retries and Git errors leave checks incomplete. Inspect unknown results before repeating a large run, since unresolved records are retried first. HTTP 429 pauses the command with exit code 75 and stores a cooldown shared by commands using that directory. Rerun after the reported time; completed work remains saved.

The default disk reserve is 5 GiB, adjustable with `--min-free-gib`. Checks run before network requests and writes. Response bodies are limited to 32 MiB, and a directory lock admits one command at a time. Oversized package pages are retried with half as many records; the retry resumes at the same position and deduplicates any overlap. The smaller page size is saved for subsequent requests and resumes. A single package exceeding the limit leaves that registry incomplete. The `clones` and `history` commands download repository objects.

### Current commits and release tags

HEAD checks use `git ls-remote --symref`, without a clone or checkout. Observed SHA-1 commit identifiers are stored before a separate command deduplicates them into batches of at most 1,000 for Software Heritage's `POST /api/1/known/` lookup. The client restricts requests to an allowlist of read-only endpoints. An optional `SWH_API_TOKEN` is sent only to Software Heritage; evidence files omit it.

`tags` reads the latest release numbers saved during package collection, including from cached responses for existing investigations. It lists remote tags without cloning, and takes repositories with a confirmed missing HEAD first. It first matches package-qualified names such as `name@version`, `name-version` or `name/vversion`, then exact `version` or `vversion` names. Multiple matches remain ambiguous, and unmatched versions and missing version metadata are listed separately. These naming matches are candidates for the package release, especially for repositories containing several packages. Tag-name ordering is not used to infer publication dates.

Matched tag targets are queued as revision lookups, and annotated tag objects as release lookups. `known` deduplicates these with HEAD identifiers and processes pending HEADs first, in batches of up to 1,000 identifiers. Git ref listings do not establish the target's object type: an absent target revision is reported as `revision_not_found`, since a tag may point to a tree or file. Annotated release presence is reported separately. Compressed ref evidence is limited to 2 MiB of Git output per repository and supports `tags --offline`.

### Repository origins

Check HEAD identifiers in batches before spending requests on origin history. `origins --missing-heads` selects only repositories whose observed HEAD received an explicit `known: false` result, and skips repositories whose origin coverage is already conclusive. Missing, failed or pending HEAD checks remain unresolved. Omit `--missing-heads` to check origin history independently for all repositories. Origin lookups stop at the first snapshot found across candidate URLs.

After tag lookups, `origins --missing-releases` investigates repositories with a matched tag target absent as a revision or an annotated release object confirmed missing. It skips repositories with any existing archival evidence (a snapshot, HEAD, matched release revision or annotated release object) and those with completed origin checks, and runs separately from `--missing-heads`. `report` includes the whole release-gap group in `out/release_gap_repositories.csv`, distinguishing archival evidence, no snapshot at the checked origins, and unresolved cases. Finding some archived content does not resolve the missing release objects, and a failed revision lookup does not establish the tag target's Git object type.

Origin results distinguish `snapshot_found`, `no_snapshot`, `origin_not_found`, `unknown` and `unchecked`. A partial visit with a snapshot establishes some coverage, and its partial status remains in the evidence. Each run checks up to eight candidate URLs per repository and three visit pages per URL. Later runs retain conclusive observations and check untried aliases before retrying unknown results. Observations completed before a rate limit or interruption are saved. Untried aliases and incomplete visit lookups keep the result unknown unless a snapshot was found. Absence means no snapshot found at the checked URLs; other aliases or mirrors may exist.

### Visit freshness

`bundle exec ruby swh-critical.rb freshness --data data/full` compares the latest visit attempt with the latest full or partial visit carrying a snapshot, using cached pages for candidate aliases, including responses saved by later investigations, and makes no network requests. `out/freshness.json` retains visit status, alias, cache timestamp, local Git errors and incomplete lookups. Each repository has separate `current_origin` and `other_aliases` results; the top-level dates cover both. Current-origin URLs normalize to the stored repository URL, including `.git` suffixes and GitHub case variants. Other aliases may include historical URLs or mirrors. That classification does not check redirects or establish which URL is current upstream.

`out/freshness_summary.json` includes the same separation in totals, forge-host and registry groups, and the missing-HEAD comparison. Each scope has its own completeness counts and sample sizes for date statistics. A repository shared by registries appears once in each registry group; package counts include only packages in that registry with repository links.

Visit ages measure elapsed days between a visit and the report, without establishing when particular commits were ingested. Statistics use repositories with complete latest-visit lookups across their checked aliases; untried aliases remain listed separately. [SWH returns visits in descending date order](https://docs.softwareheritage.org/devel/swh-web/uri-scheme-api-origin.html), so reading stops at the first snapshot-bearing visit. Unread pages, missing cached pages and the three-page limit remain recorded. The cache timestamps define the observation window; this command does not refresh upstream observations.

### Clones and historical revisions

`bundle exec ruby swh-critical.rb clones --data data/full --swhid /path/to/swhid` checks repositories with release gaps and no snapshot found at their checked origins. It makes one full mirror clone at a time, generates snapshot and HEAD revision SWHIDs using the supplied executable, and removes the temporary clone after processing. It records the tool version and saves compressed refs and commit IDs. The snapshot identifier is built from the tool's HEAD, branch and tag representation; an archival loader may select refs differently. Git submodules and LFS payloads are not downloaded.

Clone results are saved after each repository in `out/clone_checks.csv`. Reruns process failed checks and leave successful ones in place. Temporary clones are removed whether the command completes, errors or is interrupted. During subprocess execution the disk reserve is checked once per second, output is capped at 32 MiB, and commands time out after ten minutes. Existing checkouts under `~/code/<owner>/<repo>` or `~/code/<repo>` are flagged for review and left in place. The command computes identifiers locally and does not submit archival requests.

`bundle exec ruby swh-critical.rb clone-known --data data/full --limit 100000` checks saved snapshot and historical revision IDs through `/known/`, with snapshots first and at most 1,000 identifiers per request. Shared IDs are deduplicated and completed checks are reused. The default limit is 1,000 IDs per invocation. Results are saved in `out/clone_known.csv` and `out/clone_known_summary.json`, including when a request fails or hits a rate limit. These reports separate matched objects, unmatched checked objects and incomplete checks. They cover the history reachable in the saved clones; other snapshots, deleted refs or unreachable commits may still exist in the archive.

`bundle exec ruby swh-critical.rb history --data data/full` maps known revisions onto Git history for cloned repositories with some archived commits. It clones one repository at a time, saves parent links and commit dates, and removes the clone. Analysis uses the HEAD and revision set saved by `clones`, which fixes the baseline against new upstream commits. The CSV and JSON reports in `out/history_coverage.*` show the first-parent coverage pattern, the nearest archived first-parent ancestor, and archived commits outside HEAD's ancestry. They also count missing parents of archived commits. Dates are Git committer dates, not archival visit dates; a continuous older history is consistent with a stale capture but does not identify which origin supplied it. Cached graphs can be analyzed with `--offline`.

### Searching and tracing other origins

`bundle exec ruby swh-critical.rb origin-search --data data/full` searches for the saved clone URLs using SWH's case-insensitive origin search. It checks visits for matching repository URLs and `pkg.go.dev` references, while keeping other substring matches separate. Results are saved in `out/origin_search.json`. A package-registry snapshot can preserve extracted source contents without preserving Git history; its presence alone does not explain a matching Git revision.

`bundle exec ruby swh-critical.rb trace --data data/full --repositories repositories.txt` compares snapshot revision targets with saved history for repository URLs listed one per line. It searches one page of up to 1,000 origins and checks at most 12 candidates per repository, recorded aliases first. The report in `out/origin_traces.json` identifies shared commits and exact matches for the newest archived first-parent ancestor. These matches establish shared history without identifying its first ingestion source. Candidate limits and incomplete snapshot pagination are recorded; an unsuccessful search does not establish absence elsewhere in the archive.

### Source trees and file contents

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

### Restoring a published package

To recover a published package from its archived source, start with its registry and name in a separate investigation directory:

```sh
bundle exec ruby swh-critical.rb restore --data data/recovery-demo --registry npmjs.org --package possible-typed-array-names
```

`restore` reads package and version metadata from ecosyste.ms, derives the native npm, CRAN or Hackage origin, and follows the selected version's snapshot branch to its source directory. It defaults to the latest version in ecosyste.ms; use `--package-version` to select another. It downloads file bodies from SWH, verifies content hashes and the reconstructed directory hash, then publishes the files under `restored/`. The evidence manifest is `out/recovery.json`. This needs no repository clone, registry tarball or supplied SWHID. It recovers the extracted package files; Git history, omitted repository files, dependencies and the original tarball bytes remain outside that result. Recovery writes the files to disk and stops there.

Recovery is capped at 100 MiB of file contents, 10,000 files, 1,000 directories and 32 directory levels, with the same disk reserve and response limits as other commands. Unsupported entries and symlinks escaping the restored directory are rejected. Partial output is removed on failure, while cached responses support resuming and `--offline` replay. An existing `restored/` directory must match the expected tree; use a new investigation directory for another package or version.

### Extrinsic metadata

`bundle exec ruby swh-critical.rb extrinsic-metadata --data data/full --targets targets.txt` reads core SWHIDs, one per line, and queries their metadata authorities, records and payloads using GET requests. `out/extrinsic_metadata.json` retains authority, format, fetcher, discovery date, object context and cached evidence. The report includes JSON payloads inline and keeps other payloads base64-encoded in the cache. Each payload has a byte count and SHA-256 checksum. The command does not submit metadata or change object coverage.

Each run processes up to 100 pending targets by default, with `--limit` to change that count. Per target, it checks up to ten authorities and three pages of ten records per authority. Results stay incomplete when a limit is hit, a request fails or a payload is missing. Rerunning resumes through the cache, and `--offline` reads from it exclusively. A successful empty authority list describes only the requested object, and does not establish that the object or its package links are absent elsewhere. The [SWH metadata API](https://docs.softwareheritage.org/devel/apidoc/swh.web.api.views.metadata.html) documents the authority and record lookup endpoints.

### Recovering missing repository links

Recover missing links with `bundle exec ruby swh-critical.rb recover --data data/full --mappings data/full/recoveries.csv`. The CSV needs `registry,purl,repository_url,evidence_url,evidence_file,reason` columns. Verify each link against upstream package metadata first; cached repository metadata can refer to an unrelated project. Evidence files must be saved inside the investigation directory, with paths relative to it. Recovery fills missing links, retains the original values and records the evidence file's SHA-256. It rejects conflicting mappings and can be rerun. Run `heads` and `known` again to check newly added repositories. Reports include the recovery count and a `repository_recoveries.csv` evidence export.

### Scientific project and dependency comparison

Collect science metadata in a separate directory so it can run alongside the coverage scan:

```sh
bundle exec ruby swh-critical.rb science --data data/science --per-page 1000 --limit 1
bundle exec ruby swh-critical.rb science-report --data data/science --cohort data/full
bundle exec ruby swh-critical.rb science --data data/science --per-page 1000
```

`science` reads the science service's `projects/search_seeds` and `packages` endpoints. `--limit` caps pages per source for a pilot; omit it to finish both lists. Project pages are capped at 100 records and package pages at 1,000. Pagination resumes from the last saved page, with the same disk reserve, response limits, evidence cache and rate-limit handling as the coverage checks. Collections are dated observation windows over live data, and a new directory refreshes them.

`science-report` reads a consistent snapshot of the cohort database without taking its command lock or changing it. It writes `out/science_summary.json`, `out/science_packages.csv` and `out/science_matches.csv` in the science directory, and can be run again as either collection progresses. Project matches use versionless PURLs, normalized repository URLs and recorded previous repository names. Scientific dependency matches require a PURL match; a shared monorepo alone does not establish that a particular package is used by research software. Match methods and source evidence are retained in the CSV.

The two science groups overlap because they come from different filters. Projects come from the service's visible scientific project selection, currently a science score of at least 20. Dependencies come from its direct scientific-use listing, which applies its own repository science-score filter. Unmatched records remain `not_matched_yet` until both lists finish, then `not_matched`; neither means the package is unrelated to research. A repository is unmatched only when none of its cohort packages match, although individual packages within a matched monorepo can remain unmatched. Coverage counts use distinct repository URLs; release checks are per package. All coverage figures here come from this investigation's own observations rather than the science API's aggregate SWH statistics.

## Data and reports

The committed files include `swh-critical.rb`, the code in `lib/`, tests, dependency files and this README. No collected datasets or generated reports are committed: `.gitignore` excludes the entire `data/` directory, including SQLite databases, cached responses, logs, CSV and JSON exports, and restored package files. Each run writes to the directory passed to `--data`; reproducing the analysis requires collecting data or obtaining the saved investigation directories separately.

### Investigation directories

| Path within an investigation | Contents |
| --- | --- |
| `investigation.sqlite3` | Collected packages, repositories, object checks and progress |
| `cache/` | Compressed API responses used as evidence and for offline runs |
| `out/` | Generated JSON summaries and CSV reports |
| `restored/` | Verified package files produced by `restore` |

Successful JSON responses and JSON 404s are cached for the investigation; rate limits, server failures and HTML challenge pages are refetched. Observation records retain response timestamps and cache filenames. `--offline` reads from the cache, and `report` always runs locally. A new investigation directory is required to refresh cached observations.

### Coverage reports

`report` writes `out/summary.json`, `out/repositories.csv`, `out/packages.csv`, `out/registries.csv` and `out/release_tags.csv`. The summary includes incomplete registry scans and packages without repositories, and separates repository counts from distinct object counts. Tag matching and coverage counts are per package; shared objects are queried once. `missing_heads_repository_coverage` reports origin coverage just for repositories whose current commit is missing. A present commit does not change the separate origin coverage result. The pilot is an alphabetical sample; cohort-wide coverage comes from a full collection.

### Follow-up reports

Follow-up commands write their own reports under `out/`. Their results can establish additional archival evidence without changing the original HEAD or tag-object observations in `summary.json`.

| Command | Main reports |
| --- | --- |
| `freshness` | `freshness.json`, `freshness_summary.json` |
| `clones`, `clone-known` | `clone_checks.csv`, `clone_known.csv`, `clone_known_summary.json` |
| `history` | `history_coverage.csv`, `history_coverage.json` |
| `origin-search`, `trace` | `origin_search.json`, `origin_traces.json` |
| `origin-candidates` | `origin_candidates.json` |
| `package-contents`, `contents`, `origin-contents` | `package_contents.json`, `content_coverage.json`, `origin_contents.json` |
| `restore` | `recovery.json` |
| `extrinsic-metadata` | `extrinsic_metadata.json` |
| `science-report` | `science_summary.json`, `science_packages.csv`, `science_matches.csv` in the science directory |

### Saved September 2026 results

The findings above use `data/full/` for the main cohort, `data/science/` for the science comparison and `data/recovery-demo/` for package recovery. Selected reports were frozen under `data/analysis/final-20260924/`; `final-figures.json` collects the dated figures, and `manifest.json` records source paths and SHA-256 hashes. Raw API caches remain in their investigation directories.

These reports have separate cutoffs, especially the science and freshness comparisons. A new run can produce different results as package metadata, upstream repositories and the archive change. The Go pseudo-version and focused release audits are separate local analyses rather than commands exposed by `swh-critical.rb`.

## License

Licensed under the [MIT License](LICENSE).
