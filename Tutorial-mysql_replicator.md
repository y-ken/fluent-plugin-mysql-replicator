## Tutorial for Quickstart (mysql_replicator)

Useful when you want to:

* try this plugin quickly.
* replicate a small-to-medium table.

**Note:** the plugin keeps an in-memory hash of every row, so memory grows with
the table size (on the order of ~800MB for a 300 million row table). For large
or multiple tables, use
[`mysql_replicator_multi`](Tutorial-mysql_replicator_multi.md), which stores the
hash table in MySQL instead of Ruby memory.

### How it works

`mysql_replicator` does **not** rely on any `updated_at`/timestamp column to
detect changes. On every `interval`, it re-runs the configured `query`, computes
a hash for each returned row, and keeps an **in-memory hash table of every row**
(keyed by `primary_key`) to compare against the previous run:

* a row whose `primary_key` was not seen before → `insert` event
* a row whose hash changed since the previous run → `update` event
* a `primary_key` that disappeared from the result set → `delete` event (when `enable_delete yes`)

Because the whole result set is held in memory, this plugin is best suited for
small-to-medium tables. For millions of rows or multiple tables, prefer
[`mysql_replicator_multi`](Tutorial-mysql_replicator_multi.md), which stores the
hash table in a MySQL management table instead of Ruby memory.

The `updated_at` column is therefore not required. It only becomes useful if you
intentionally narrow the `query` to recently changed rows together with
`enable_delete no`, as shown in the `enable_delete` comment below.

### configuration

`````
<source>
  @type mysql_replicator

  # Connection settings for the replication source.
  host     localhost
  username your_mysql_user
  password your_mysql_password
  database myweb

  # Replication query.
  query       SELECT id, text FROM search_test;
  primary_key id    # a column name, or a comma-separated list for a composite key (default: id)
  interval    10s   # how often to run the query (default: 1m)

  # Detect delete events in addition to insert/update (default: yes).
  # With `enable_delete no` you can instead narrow the query to recently updated
  # rows, e.g.:
  #   SELECT * FROM search_test WHERE DATE_ADD(updated_at, INTERVAL 5 MINUTE) > NOW();
  enable_delete yes

  # Output tag. ${event} and ${primary_key} are expanded by the plugin.
  tag replicator.myweb.search_test.${event}.${primary_key}
  # ${event}       : insert / update / delete
  # ${primary_key} : the configured primary_key column name(s)
</source>

<match replicator.**>
  @type copy
  <store>
    @type stdout
  </store>
  <store>
    @type mysql_replicator_elasticsearch

    # Elasticsearch connection.
    host localhost
    port 9200

    # Derive the Elasticsearch index / type / id from the tag.
    tag_format (?<index_name>[^\.]+)\.(?<type_name>[^\.]+)\.(?<event>[^\.]+)\.(?<primary_key>[^\.]+)$

    <buffer>
      @type             file
      path              /var/log/fluent/buffer/mysql_replicator_elasticsearch
      flush_interval    5s
      flush_at_shutdown true   # flush queued chunks on shutdown (recommended)
    </buffer>
  </store>
</match>
`````

> Using the [fluent-package](https://www.fluentd.org/download/fluent_package)
> distribution? Its buffer/log directory is `/var/log/fluent/` (the old td-agent
> path was `/var/log/td-agent/`).
