# fluent-plugin-mysql-replicator [![CI](https://github.com/y-ken/fluent-plugin-mysql-replicator/actions/workflows/ci.yml/badge.svg)](https://github.com/y-ken/fluent-plugin-mysql-replicator/actions/workflows/ci.yml)

## Overview

Fluentd input plugin that tracks insert / update / delete events on a MySQL
database server, and can replicate one or many tables into Elasticsearch or Solr.

## Requirements

The current release is tested against:

| Component              | Versions |
|------------------------|----------|
| Ruby                   | 3.2, 3.3, 3.4, 4.0 |
| Fluentd                | v1.x, including [fluent-package](https://www.fluentd.org/download/fluent_package) v6 LTS (bundles Fluentd 1.19) |
| Elasticsearch (output) | 6.x – 9.x |

Older 0.6.x / 1.0.x releases ran on Fluentd v0.12 / v0.14 and Ruby >= 2.1, with
td-agent (now end-of-life) as the packaged distribution.

## Dependency

This plugin depends on the [mysql2](https://rubygems.org/gems/mysql2) gem, which
builds a native extension at install time. You need both a C compiler toolchain
**and the MySQL client development headers** before installing.

```bash
# for RHEL/CentOS/Fedora
$ sudo yum group install "Development Tools"
$ sudo yum install mysql-devel        # or mariadb-devel

# for Ubuntu/Debian (including the official fluent/fluentd Docker image)
$ sudo apt-get install build-essential default-libmysqlclient-dev
```

### Troubleshooting: "Failed to build gem native extension"

If `gem install` (or `td-agent-gem install`) fails while building the `mysql2`
native extension, the MySQL client headers are almost always missing. Install
the development package for your platform shown above, then retry the
installation. On the official `fluent/fluentd:*-debian` images, run:

```bash
$ apt-get update && apt-get install -y build-essential default-libmysqlclient-dev
```

## Installation

Install with RubyGems, or with `fluent-gem` for fluent-package:

```bash
# system-wide Fluentd (RubyGems)
$ gem install fluent-plugin-mysql-replicator

# fluent-package (the td-agent successor)
$ sudo fluent-gem install fluent-plugin-mysql-replicator
```

If the `mysql2` native extension fails to build, see the **Dependency** section
above.

## Development container

This repository includes a VS Code Dev Container configuration under `.devcontainer/`.
Use Docker and Remote Containers / Dev Containers in VS Code to build and open the workspace inside a container.
The container installs Ruby, Bundler, and required native build dependencies.

After opening the repository in the Dev Container, run:

```
bundle config set --local path vendor/bundle
bundle install
```

Then run tests like:

```
bundle exec ruby -Itest test/plugin/test_out_mysql_replicator_elasticsearch.rb
```

## Included plugins

* Input Plugin: mysql_replicator
* Input Plugin: mysql_replicator_multi
* Output Plugin: mysql_replicator_elasticsearch
* Output Plugin: mysql_replicator_solr (experimental)

## Elasticsearch version compatibility

`mysql_replicator_elasticsearch` works with Elasticsearch 6.x through 9.x.

Mapping types were removed in Elasticsearch 8.x (and deprecated in 7.x), so the
`_type` field can no longer be sent in bulk requests. The plugin detects the
Elasticsearch version on the first write and automatically omits `_type` for
7.x and later, so no extra configuration is required.

## JSON column support

MySQL `JSON` columns (MySQL 5.7.8+ / 8.x) are returned by the driver as plain
strings, so by default they reach Elasticsearch as escaped strings rather than
nested objects. List such columns in `json_columns` to have their values parsed
into nested objects before they are emitted.

* `mysql_replicator` (single): set the `json_columns` option (comma-separated).

  ```
  <source>
    @type        mysql_replicator
    # ...
    query        SELECT id, name, geometry FROM places
    json_columns geometry,attrs
  </source>
  ```

* `mysql_replicator_multi`: set the `json_columns` column (comma-separated) on
  the relevant row of the `settings` management table. Existing installs can add
  the column with:

  ```sql
  ALTER TABLE settings ADD COLUMN `json_columns` varchar(255) DEFAULT NULL AFTER `primary_key`;
  ```

Notes:

* This option is intended for Elasticsearch. **Do not set it when the destination
  cannot store JSON objects (e.g. the Solr output)** — leave it empty there.
* Only top-level columns are parsed (columns inside nested documents are not).
* Malformed JSON and non-string values are left untouched, so enabling the option
  never corrupts non-JSON data.

## Date-based index names

`mysql_replicator_elasticsearch` resolves the target index name from the tag
(via `tag_format`). If that index-name segment contains `strftime` tokens such
as `%Y%m%d`, they are expanded using the record's event time, so you can create
Logstash-style dated indices like `myindex-20180831`.

Put the tokens in the index-name part of the input plugin's `tag` (the segment
must not contain `.`, so use `%Y%m%d` or `%Y-%m-%d`):

```
<source>
  @type mysql_replicator
  # ...
  tag   myindex-%Y%m%d.mytype.${event}.${primary_key}
</source>
```

Index names that contain no `%` are left unchanged, so this is fully backward
compatible.

> **Note on deletions:** delete events target the index computed from the delete
> event's own time, so date-rotated indices are best suited to insert-only data
> (a record inserted on a previous day lives in that day's index).

## Composite primary keys

`primary_key` accepts a comma-separated list of columns, so tables keyed by more
than one column are supported:

```
<source>
  @type        mysql_replicator
  # ...
  query        SELECT tenant_id, id, name FROM items
  primary_key  tenant_id,id
</source>
```

Change detection (insert/update/delete) then keys on the combination of those
columns, and the Elasticsearch document `_id` becomes their values joined by `,`
(e.g. `10,7`). A single-column `primary_key` (the default `id`) behaves exactly
as before.

This applies to `mysql_replicator`; `mysql_replicator_multi` still expects a
single-column primary key.

## Nested documents

You can nest the rows of a sub-query under a column. Select a SQL query template
(containing a `${placeholder}`) as a column value; for each row the plugin runs
that query, substituting the placeholder with the row's column value, and nests
the results under the column:

```sql
SELECT
  id,
  title,
  'SELECT body, author FROM comments WHERE post_id = ${id}' AS comments
FROM posts;
```

Here every `posts` row gets a `comments` array built from the sub-query.

Only values matching `SELECT ... ${...}` are treated as sub-queries, so ordinary
text columns that merely begin with the word "SELECT" are left untouched.

## Index templates (mappings)

By default Elasticsearch infers field types from the first document (dynamic
mapping), and an existing field's mapping cannot be changed afterwards. To
control a field's mapping — e.g. `keyword` for a non-analyzed field, or
`geo_point`, which dynamic mapping never infers — install an **index template**
so it is applied to indices *before* the first document is written.

`mysql_replicator_elasticsearch` can install a template on startup. The option
names mirror `fluent-plugin-elasticsearch` (the default here uses the modern
composable API, whereas fluent-plugin-elasticsearch defaults to legacy):

```
<match replicator.**>
  @type mysql_replicator_elasticsearch
  # ...
  template_name        myindex_template
  template_file        /etc/fluent/myindex_template.json
  template_overwrite   false   # set true to replace an existing template
  use_legacy_template  false   # default. false: PUT /_index_template (ES >= 7.8); true: PUT /_template (legacy, ES 6.x+)
</match>
```

`template_name` and `template_file` must be set together. The template is a
**server-side rule**, so once installed it is applied automatically to every new
index whose name matches its `index_patterns` — **including future date-rolled
indices** (see *Date-based index names* above) — with no per-write work.

Example `template_file` (composable format, the default) mapping a non-analyzed
field as `keyword`, a coordinate field as `geo_point`, and a `DECIMAL` column as
a numeric (see below):

```json
{
  "index_patterns": ["myindex-*"],
  "template": {
    "mappings": {
      "properties": {
        "message":  { "type": "keyword" },
        "location": { "type": "geo_point" },
        "price":    { "type": "scaled_float", "scaling_factor": 100 }
      }
    }
  }
}
```

For Elasticsearch 6.x — or to reuse an existing `fluent-plugin-elasticsearch`
legacy template — set `use_legacy_template true` and put `settings`/`mappings`
at the top level (not under `template`).

### Numeric columns (DECIMAL)

MySQL `DECIMAL` columns are sent to Elasticsearch **as strings** — not because of
a type-inference issue, but because `BigDecimal` cannot cross Fluentd's msgpack
buffer between the input and output plugins, so the value is stringified (which
also preserves its exact precision). Under the default dynamic mapping such a
field is therefore indexed as text.

To index it as a number, map the field in your template as `double`, or — to keep
exact fixed-point precision — `scaled_float` (as `price` above). Elasticsearch's
`coerce` (enabled by default for numeric types) converts the numeric string to a
number at index time, so no value conversion is needed in the plugin.

## Output example

An example of detecting insert/update/delete events.

### sample query

`````
$ mysql -e "create database myweb"
$ mysql myweb -e "create table search_test(id int auto_increment, text text, PRIMARY KEY (id))"
$ sleep 10
$ mysql myweb -e "insert into search_test(text) values('aaa')"
$ sleep 10
$ mysql myweb -e "update search_test set text='bbb' where text = 'aaa'"
$ sleep 10
$ mysql myweb -e "delete from search_test where text='bbb'"
`````

### result

`````
$ tail -f /var/log/fluent/fluentd.log
2013-11-25 18:22:25 +0900 replicator.myweb.search_test.insert.id: {"id":"1","text":"aaa"}
2013-11-25 18:22:35 +0900 replicator.myweb.search_test.update.id: {"id":"1","text":"bbb"}
2013-11-25 18:22:45 +0900 replicator.myweb.search_test.delete.id: {"id":"1"}
`````

## Tutorial

### mysql_replicator

It is easy to try out quickly.  
More details are described in [Tutorial-mysql_replicator.md](https://github.com/y-ken/fluent-plugin-mysql-replicator/blob/master/Tutorial-mysql_replicator.md)

**Features**

* Synchronizes a table (or a view).
* Best suited to small-to-medium tables (the whole result set is held in memory).
* Insert-only tables work best.
* Composite primary keys are supported (see *Composite primary keys* above).
* Nested documents are supported via a `${...}` placeholder sub-query (see *Nested documents* above).

**Examples**

* [mysql_single_table_to_elasticsearch.md](https://github.com/y-ken/fluent-plugin-mysql-replicator/blob/master/example/mysql_single_table_to_elasticsearch.md)
* [mysql_single_table_to_solr.md](https://github.com/y-ken/fluent-plugin-mysql-replicator/blob/master/example/mysql_single_table_to_solr.md)

### mysql_replicator_multi

It replicates millions of records and/or multiple tables with multiple threads.  
This architecture stores the hash table in a MySQL management table instead of Ruby memory.  
See the tutorial at [Tutorial-mysql_replicator_multi.md](https://github.com/y-ken/fluent-plugin-mysql-replicator/blob/master/Tutorial-mysql_replicator_multi.md)

**Features**

* Synchronizes a table (or a view).
* Replicates multiple tables, with each source connection/query stored in a MySQL management table.
* Uses a MySQL table as the hash-table cache, so it scales to tables with millions of rows.
* Best suited to replicating whole tables.
* Nested documents are supported via a `${...}` placeholder sub-query (see *Nested documents* above).

**Examples**

* [mysql_multi_table_to_elasticsearch.md](https://github.com/y-ken/fluent-plugin-mysql-replicator/blob/master/example/mysql_multi_table_to_elasticsearch.md)
* [mysql_multi_table_to_solr.md](https://github.com/y-ken/fluent-plugin-mysql-replicator/blob/master/example/mysql_multi_table_to_solr.md)

## Articles

* MySQLテーブルへの更新/削除イベントを逐次取得するFluentdプラグイン「fluent-plugin-mysql-replicator」をリリースしました - Y-Ken Studio<br />
http://y-ken.hatenablog.com/entry/fluent-plugin-mysql-replicator-has-released

* MySQLユーザ視点での小さく始めるElasticsearch<br />
http://www.slideshare.net/y-ken/introducing-elasticsearch-for-mysql-users

* MySQLからelasticsearchへ、レコードをネスト構造化しつつ同期出来る fluent-plugin-mysql-replicator v0.4.0 を公開しました - Y-Ken Studio<br />
http://y-ken.hatenablog.com/entry/fluent-plugin-mysql-repicator-v0.4.0

## TODO

Pull requests are very welcome, for example:

* more documentation and examples
* composite primary key support for `mysql_replicator_multi`
* reload settings on demand

## Copyright

Copyright © 2013- Kentaro Yoshida ([@yoshi_ken](https://twitter.com/yoshi_ken))

## License

Apache License, Version 2.0
