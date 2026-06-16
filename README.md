# fluent-plugin-mysql-replicator [![CI](https://github.com/y-ken/fluent-plugin-mysql-replicator/actions/workflows/ci.yml/badge.svg)](https://github.com/y-ken/fluent-plugin-mysql-replicator/actions/workflows/ci.yml)

## Overview

Fluentd input plugin to track insert/update/delete event from MySQL database server.  
Not only that, it could multiple table replication into single or multi Elasticsearch/Solr.  
It's comming support replicate to another RDB/noSQL.

## Requirements

| fluent-plugin-mysql-replicator | fluentd    | ruby   |
|--------------------|------------|--------|
|  >= 0.6.1          | >= v0.14.x | >= 2.1 |
|  <= 0.6.1          | >= v0.12.x | >= 1.9 |

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

install with gem or fluent-gem command as:

`````
# for system installed fluentd
$ gem install fluent-plugin-mysql-replicator -v 1.0.3

# for td-agent2
$ sudo td-agent-gem install fluent-plugin-mysql-replicator -v 0.6.1

# for td-agent3
$ sudo td-agent-gem install fluent-plugin-mysql-replicator -v 1.0.3
`````

## Development container

This repository includes a VS Code Dev Container configuration under `.devcontainer/`.
Use Docker and Remote Containers / Dev Containers in VS Code to build and open the workspace inside a container.
The container installs Ruby, Bundler, and required native build dependencies.

After opening the repository in the Dev Container, run:

```
bundle install --path vendor/bundle
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

## Index templates (mappings)

By default Elasticsearch infers field types from the first document (dynamic
mapping), and an existing field's mapping cannot be changed afterwards. To
control a field's mapping — e.g. `keyword` for a non-analyzed field, or
`geo_point`, which dynamic mapping never infers — install an **index template**
so it is applied to indices *before* the first document is written.

`mysql_replicator_elasticsearch` can install a template on startup. The option
names and defaults mirror `fluent-plugin-elasticsearch`:

```
<match replicator.**>
  @type mysql_replicator_elasticsearch
  # ...
  template_name        myindex_template
  template_file        /etc/fluent/myindex_template.json
  template_overwrite   false   # set true to replace an existing template
  use_legacy_template  true    # true: PUT /_template (ES 6.x+); false: PUT /_index_template (ES >= 7.8)
</match>
```

`template_name` and `template_file` must be set together. The template is a
**server-side rule**, so once installed it is applied automatically to every new
index whose name matches its `index_patterns` — **including future date-rolled
indices** (see *Date-based index names* above) — with no per-write work.

Example `template_file` (legacy format, the default) mapping a non-analyzed
field as `keyword` and a coordinate field as `geo_point`:

```json
{
  "index_patterns": ["myindex-*"],
  "mappings": {
    "properties": {
      "message":  { "type": "keyword" },
      "location": { "type": "geo_point" }
    }
  }
}
```

With `use_legacy_template false`, use the composable template format instead
(wrap `settings`/`mappings` under a `template` object); this requires
Elasticsearch 7.8 or later.

## Output example

It is a example when detecting insert/update/delete events.

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
$ tail -f /var/log/td-agent/td-agent.log
2013-11-25 18:22:25 +0900 replicator.myweb.search_test.insert.id: {"id":"1","text":"aaa"}
2013-11-25 18:22:35 +0900 replicator.myweb.search_test.update.id: {"id":"1","text":"bbb"}
2013-11-25 18:22:45 +0900 replicator.myweb.search_test.delete.id: {"id":"1"}
`````

## Tutorial

### mysql_replicator

It is easy to try it on this plugin quickly.  
For more detail are described at [Tutorial-mysql_replicator.md](https://github.com/y-ken/fluent-plugin-mysql-replicator/blob/master/Tutorial-mysql_replicator.md)

**Features**

* Table (or view table) synchronization supported.
* Replicate small record under a millons table.
* It is recommend to use insert only table.
* Nested documents are supported with placeholder which accessing to temporary table created at the each loop.

**Examples**

* [mysql_single_table_to_elasticsearch.md](https://github.com/y-ken/fluent-plugin-mysql-replicator/blob/master/example/mysql_single_table_to_elasticsearch.md)
* [mysql_single_table_to_solr.md](https://github.com/y-ken/fluent-plugin-mysql-replicator/blob/master/example/mysql_single_table_to_solr.md)

### mysql_replicator_multi

It replicates a millions of records and/or multiple tables with multiple threads.  
This architecture is storing hash table in MySQL management table instead of ruby internal memory.  
See tutorial at [Tutorial-mysql_replicator_multi.md](https://github.com/y-ken/fluent-plugin-mysql-replicator/blob/master/Tutorial-mysql_replicator_multi.md)

**Features**

* table (or view table) synchronization supported.
* Multiple table synchronization supported and its DSN stored in MySQL management table.
* Using MySQL database as hash table cache to support replicate over a millions table.
* It is recommend to make whole copy of tables.
* Nested documents are supported with placeholder which accessing to temporary table created at the each loop.

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

Pull requests are very welcome like below!!

* more documents
* more tests with mock.
* support string type of primary_key.
* support reload setting on demand.

## Copyright

Copyright © 2013- Kentaro Yoshida ([@yoshi_ken](https://twitter.com/yoshi_ken))

## License

Apache License, Version 2.0
