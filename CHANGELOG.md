# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-06-16

### Added
- JSON column support for nested object indexing. The new opt-in `json_columns`
  option parses MySQL `JSON` string columns into nested objects before they are
  emitted, so Elasticsearch indexes them as real nested JSON instead of escaped
  strings. Available on both `mysql_replicator` (config option) and
  `mysql_replicator_multi` (new `json_columns` column on the `settings` table).
  Malformed JSON and non-string values are left untouched. ([#48], implements [#18])

### Fixed
- Delete detection no longer raises `bad value for range` (and no longer
  allocates a huge array or emits phantom delete events) when the `primary_key`
  is non-integer (e.g. a UUID `CHAR(36)`) or a large/sparse integer. The first
  poll now only establishes a baseline. ([#42])
- In `mysql_replicator`, a nested sub-query is now triggered only when a column
  value is an actual query template containing a `${placeholder}`. Previously any
  value that merely began with the word `SELECT` was executed as SQL. This aligns
  the single plugin with the fix already present in `mysql_replicator_multi`. ([#4])

### Documentation
- Document that the `mysql2` native extension requires the MySQL client
  development headers (`default-libmysqlclient-dev` / `mysql-devel`), add a
  "Failed to build gem native extension" troubleshooting note, and clarify that
  change detection uses an in-memory hash of every row (not an `updated_at`
  column). ([#43], [#40])

### CI
- Add install-smoke jobs that build and install the gem on **fluent-package v6
  LTS** (the td-agent successor) and on the official `fluent/fluentd` image,
  guarding against native-extension build regressions.

## [1.1.0] - 2026-06-15

### Added
- Auto-detect the Elasticsearch version on first write and support Elasticsearch
  6.x through 9.x. The `_type` field is omitted automatically for 7.x and later,
  where mapping types were removed.
- Dev Container configuration and end-to-end (E2E) replication tests, including
  multi-table replication.

### Changed
- Migrated CI to GitHub Actions (removed Travis CI) and run the unit-test matrix
  on Ruby 3.2–4.0, aligned with supported Fluentd versions.

## [1.0.3] - 2024-02-28

### Added
- Reconnection option to recover from database connection errors. ([#45])

## [1.0.2] - 2021-10-27

### Fixed
- Manage threads correctly in `mysql_replicator_multi`. ([#39])

## [1.0.1] - 2019-11-19

### Fixed
- Ensure the nested-query database connection (`nest_db`) is always closed.

### Documentation
- Documentation updates.

## [1.0.0] - 2019-11-13

- First 1.0 release, targeting the Fluentd v0.14+ plugin API. Earlier 0.x
  history is available in the git log.

[1.2.0]: https://github.com/y-ken/fluent-plugin-mysql-replicator/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/y-ken/fluent-plugin-mysql-replicator/compare/v1.0.3...v1.1.0
[1.0.3]: https://github.com/y-ken/fluent-plugin-mysql-replicator/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/y-ken/fluent-plugin-mysql-replicator/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/y-ken/fluent-plugin-mysql-replicator/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/y-ken/fluent-plugin-mysql-replicator/releases/tag/v1.0.0

[#4]: https://github.com/y-ken/fluent-plugin-mysql-replicator/issues/4
[#18]: https://github.com/y-ken/fluent-plugin-mysql-replicator/pull/18
[#39]: https://github.com/y-ken/fluent-plugin-mysql-replicator/pull/39
[#40]: https://github.com/y-ken/fluent-plugin-mysql-replicator/issues/40
[#42]: https://github.com/y-ken/fluent-plugin-mysql-replicator/issues/42
[#43]: https://github.com/y-ken/fluent-plugin-mysql-replicator/issues/43
[#45]: https://github.com/y-ken/fluent-plugin-mysql-replicator/pull/45
[#48]: https://github.com/y-ken/fluent-plugin-mysql-replicator/pull/48
