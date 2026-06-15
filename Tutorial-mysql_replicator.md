## Tutorial for Quickstart (mysql_replicator)

It is useful for these purpose.

* try it on this plugin quickly.
* replicate small record under a millons table.

**Note:**  
On syncing 300 million rows table, it will consume around 800MB of memory with ruby 1.9.3 environment.

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
  type mysql_replicator

  # Set connection settings for replicate source.
  host localhost
  username your_mysql_user
  password your_mysql_password
  database myweb

  # Set replicate query configuration.
  query SELECT id, text from search_test;
  primary_key id # specify unique key (default: id)
  interval 10s  # execute query interval (default: 1m)

  # Enable detect deletion event not only insert/update events. (default: yes)
  # It is useful to use `enable_delete no` that keep following recently updated record with this query.
  # `SELECT * FROM search_test WHERE DATE_ADD(updated_at, INTERVAL 5 MINUTE) > NOW();`
  enable_delete yes

  # Format output tag for each events. Placeholders usage as described below.
  tag replicator.myweb.search_test.${event}.${primary_key}
  # ${event} : the variation of row event type by insert/update/delete.
  # ${primary_key} : the value of `replicator_manager.settings.primary_key` in manager table.
</source>

<match replicator.*>
  type copy
  <store>
    type stdout
  </store>
  <store>
    type mysql_replicator_elasticsearch

    # Set Elasticsearch connection.
    host localhost
    port 9200

    # Set Elasticsearch index, type, and unique id (primary_key) from tag.
    tag_format (?<index_name>[^\.]+)\.(?<type_name>[^\.]+)\.(?<event>[^\.]+)\.(?<primary_key>[^\.]+)$

    # Set frequency of sending bulk request to Elasticsearch node.
    flush_interval 5s
    
    # Queued chunks are flushed at shutdown process. (recommend for more stability)
    # It's sample for td-agent. If you use Yamabiko, replace path from 'td-agent' to 'yamabiko'.
    flush_at_shutdown yes
    buffer_type file
    buffer_path /var/log/td-agent/buffer/mysql_replicator_elasticsearch
  </store>
</match>
`````
