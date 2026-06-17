# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] - 2026-06-17

### Added
- Plugin-managed Elasticsearch index templates. New `template_name`,
  `template_file`, `template_overwrite`, and `use_legacy_template` options on
  `mysql_replicator_elasticsearch` install an index template on startup, so newly
  created indices — including future date-rolled ones — get the desired mapping
  before the first document locks in dynamic mapping. This enables mappings that
  cannot be changed after the fact: `keyword` / non-analyzed fields ([#20]) and
  `geo_point` ([#36]). `use_legacy_template` defaults to `false` (composable
  `PUT /_index_template`, Elasticsearch >= 7.8); set it to `true` for the legacy
  `PUT /_template` API (Elasticsearch 6.x+).

### Documentation
- Document that MySQL `DECIMAL` columns are emitted as strings (because
  `BigDecimal` cannot cross Fluentd's msgpack buffer, which also preserves exact
  precision) and should be mapped as `double` or `scaled_float` in an index
  template, where Elasticsearch coerces the numeric string at index time. ([#36])

## [1.3.0] - 2026-06-16

### Added
- Date-based Elasticsearch index names. If the index-name segment of the tag
  contains `strftime` tokens (e.g. `%Y%m%d`), they are expanded using the
  record's event time, enabling Logstash-style dated indices such as
  `myindex-20180831`. Index names without a `%` are unchanged. ([#27])
- Composite primary key support in `mysql_replicator`. `primary_key` now accepts
  a comma-separated list of columns; the combination is used for change
  detection and as the Elasticsearch document `_id` (values joined by `,`). A
  single-column key behaves exactly as before. ([#7])

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

[1.4.0]: https://github.com/y-ken/fluent-plugin-mysql-replicator/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/y-ken/fluent-plugin-mysql-replicator/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/y-ken/fluent-plugin-mysql-replicator/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/y-ken/fluent-plugin-mysql-replicator/compare/v1.0.3...v1.1.0
[1.0.3]: https://github.com/y-ken/fluent-plugin-mysql-replicator/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/y-ken/fluent-plugin-mysql-replicator/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/y-ken/fluent-plugin-mysql-replicator/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/y-ken/fluent-plugin-mysql-replicator/releases/tag/v1.0.0

[#4]: https://github.com/y-ken/fluent-plugin-mysql-replicator/issues/4
[#7]: https://github.com/y-ken/fluent-plugin-mysql-replicator/pull/7
[#18]: https://github.com/y-ken/fluent-plugin-mysql-replicator/pull/18
[#20]: https://github.com/y-ken/fluent-plugin-mysql-replicator/issues/20
[#27]: https://github.com/y-ken/fluent-plugin-mysql-replicator/issues/27
[#36]: https://github.com/y-ken/fluent-plugin-mysql-replicator/issues/36
[#39]: https://github.com/y-ken/fluent-plugin-mysql-replicator/pull/39
[#40]: https://github.com/y-ken/fluent-plugin-mysql-replicator/issues/40
[#42]: https://github.com/y-ken/fluent-plugin-mysql-replicator/issues/42
[#43]: https://github.com/y-ken/fluent-plugin-mysql-replicator/issues/43
[#45]: https://github.com/y-ken/fluent-plugin-mysql-replicator/pull/45
[#48]: https://github.com/y-ken/fluent-plugin-mysql-replicator/pull/48
