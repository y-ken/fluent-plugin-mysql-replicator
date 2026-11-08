# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.1] - 2026-11-09

### Fixed
- Elasticsearch output: it could not be loaded on Fluentd 1.20.1, which no
  longer bundles yajl-ruby (`cannot load such file -- yajl`). It now uses the
  `json` library that comes with Ruby instead of yajl-ruby, so no gem needs to be
  installed for it. ([#61])
  - Strings that are not valid UTF-8, such as values of `BLOB` or `BINARY`
    columns, are written with U+FFFD in place of the invalid bytes, the same way
    on json 2.x and 3.x, and one warning per chunk gives the number of values
    replaced (not the values). With yajl, the bytes were sent as they were, and
    Elasticsearch rejected the document.
  - A row whose primary key is not valid UTF-8, such as a `BINARY(16)` key from
    `UUID_TO_BIN(UUID())`, is skipped, for an index and for a delete, and one
    warning per chunk gives the number of rows and the indices, as replacing its
    bytes would give different rows the same `_id`. The other rows of the chunk
    are written. With yajl, Elasticsearch rejected the whole bulk request for
    most such keys, so the other rows were not written either.
- Solr output: every write failed on Ruby 3.0 and later. Building the core URL
  raised `NoMethodError` (`URI.escape` was removed in Ruby 3.0), and so did the
  commit at the end of the write, so the chunk was retried and never committed.
  ([#62])
- Elasticsearch and Solr outputs: a chunk with a record whose tag does not match
  `tag_format` now fails with `Fluent::UnrecoverableError` and a message that
  names the tags (up to ten, with their counts), `tag_format` and the number of
  records, instead of `NoMethodError` (`undefined method '[]' for nil`). As
  before, Fluentd moves the whole chunk at once, without retrying it, to the
  backup directory or to `<secondary>`: the records of the chunk whose tag
  matches are not written either. ([#63])
- Elasticsearch output: the version detection and the index template install are
  tried again after a failure that can go away. Before, one failed `GET /` on the
  first write, for example while Elasticsearch was starting, made the output send
  `_type` until a restart, which Elasticsearch 8 and 9 reject, so no chunk was
  written to them; and a template install that failed once was never tried again, so new
  indices got dynamic mapping. ([#64])
  - When `GET /` or a request to the template API fails with a connection error,
    a 429 or a 5xx, the write logs a warning and fails without sending the bulk
    request, and Fluentd retries the chunk, which tries the version and the
    template again. So `_type` is not guessed, and no index is created with
    dynamic mapping before the template is in.
  - While only the template API keeps failing this way, no bulk request is sent
    at all, where 1.4.0 went on writing without the template. The chunks wait in
    the buffer: with a memory buffer (the default of this output) and no
    `<secondary>`, Fluentd drops the chunks in the buffer queue when the retry
    limit is reached, and with `retry_forever` they stay queued and new input can
    fill the buffer.
  - Any other failure, such as 403 on `GET /` for a user without the `monitor`
    privilege, 400 for a broken template or a `template_file` that cannot be
    read, is logged once as an error and not tried again until a restart, and
    the bulk request is sent, as before: with `_type` (assuming 6.x) when the
    version is unknown, and without the template.
  - The tags are checked before any request to Elasticsearch, so a chunk with a
    tag that does not match `tag_format` still goes to the backup at once while
    `GET /` or the template API fails.
  - With `flush_thread_count` 2 or more, the version is detected and the template
    installed once, and the other flushes wait for them before they send their
    bulk requests.
- Elasticsearch output: documents that failed in a bulk request were dropped
  without a log. Elasticsearch answers 200 with `"errors": true` when some
  documents fail, for example on a mapping error. The output now logs one error
  per such request, with the number of failed documents and, for up to five of
  them, the index, the status and the error type. The `_id` and the reason of the
  error are not logged, as they can contain values of the row. A delete that
  answers 404 is not counted. The failed documents are still not retried, and a
  response that cannot be read gives one warning, without failing the write.
  ([#65])

  ```
  mysql_replicator_elasticsearch: 1 of 2 documents failed in a bulk request: index=users status=400 type=document_parsing_exception
  ```

### Documentation
- The README has a new section, "A tag that does not match `tag_format`", on the
  log and on where the chunk goes. ([#63]) It also says what happens when the
  version detection or the template install fails, and that the template is
  installed on the first write, not on startup.

### CI
- The install-smoke jobs load the output plugins too, so that a library that
  Fluentd stops bundling is caught, and the unit tests also run with json 2.21.x
  on Ruby 3.4. ([#61])
- The E2E tests run on Elasticsearch 6.8, 7.17, 8.19 and 9.5, and check that the
  plugin installs the index template. ([#86])
- The fluent-package install-smoke job runs on Ubuntu 24.04, as the install
  script is for that release only. ([#88])

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

[1.4.1]: https://github.com/y-ken/fluent-plugin-mysql-replicator/compare/v1.4.0...v1.4.1
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
[#61]: https://github.com/y-ken/fluent-plugin-mysql-replicator/pull/61
[#62]: https://github.com/y-ken/fluent-plugin-mysql-replicator/pull/62
[#63]: https://github.com/y-ken/fluent-plugin-mysql-replicator/pull/63
[#64]: https://github.com/y-ken/fluent-plugin-mysql-replicator/pull/64
[#65]: https://github.com/y-ken/fluent-plugin-mysql-replicator/pull/65
[#86]: https://github.com/y-ken/fluent-plugin-mysql-replicator/pull/86
[#88]: https://github.com/y-ken/fluent-plugin-mysql-replicator/pull/88
