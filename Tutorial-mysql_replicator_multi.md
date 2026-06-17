## Tutorial for Production (mysql_replicator_multi)

Useful to replicate millions of records and/or multiple tables with multiple
threads. This variant stores the comparison hash table in a MySQL management
table instead of Ruby memory, so its memory footprint stays small (on the order
of ~20MB even for a 300 million row table).

### prepare

Two steps:

* create the management database and tables.
* add a replicator configuration row.

##### create database and tables

```
$ mysql -umysqluser -p

-- For the first time, load the schema.
mysql> source /path/to/setup_mysql_replicator_multi.sql
```

See [setup_mysql_replicator_multi.sql](https://github.com/y-ken/fluent-plugin-mysql-replicator/blob/master/setup_mysql_replicator_multi.sql).
If you don't have it locally, download it first:

```
$ wget https://raw.githubusercontent.com/y-ken/fluent-plugin-mysql-replicator/master/setup_mysql_replicator_multi.sql
```

##### add replicator configuration

```sql
-- Set the working database.
mysql> use replicator_manager;

-- Add a replication source connection and its query settings.
mysql> INSERT INTO `settings`
  (`is_active`, `name`, `host`, `port`, `username`, `password`, `database`,
   `query`, `prepared_query`, `interval`, `primary_key`, `enable_delete`)
VALUES
  (1, 'mydb.mytable', '192.168.100.221', 3306, 'mysqluser', 'mysqlpassword', 'mydb',
   'SELECT id, text FROM mytable;', '', 5, 'id', 1);
```

The inserted row then looks like this — the columns you didn't set fall back to
their defaults:

| id | is_active | name | host | port | username | password | database | query | prepared_query | interval | primary_key | json_columns | enable_delete | enable_loose_insert | enable_loose_delete | enable_retry | retry_interval |
|----|-----------|------|------|------|----------|----------|----------|-------|----------------|----------|-------------|--------------|---------------|---------------------|---------------------|--------------|----------------|
| 1 | 1 | mydb.mytable | 192.168.100.221 | 3306 | mysqluser | mysqlpassword | mydb | SELECT id, text FROM mytable; |  | 5 | id | NULL | 1 | 0 | 0 | 1 | 30 |

The optional columns have sensible defaults:

* `json_columns` — comma-separated MySQL `JSON` columns to parse into nested
  objects (see the [README](README.md#json-column-support)).
* `enable_retry` (default `1`) / `retry_interval` (default `30`) — keep retrying
  when the source database is temporarily unavailable, instead of stopping.
* `enable_loose_insert` / `enable_loose_delete` — speed/accuracy trade-offs for
  insert/delete detection.

### configuration

`````
<source>
  @type mysql_replicator_multi

  # Connection settings for the management (settings) database.
  manager_host     localhost
  manager_username your_mysql_user
  manager_password your_mysql_password
  manager_database replicator_manager

  # Output tag. ${name}, ${event} and ${primary_key} are expanded by the plugin.
  tag replicator.${name}.${event}.${primary_key}
  # ${name}        : the value of `replicator_manager.settings.name`
  # ${event}       : insert / update / delete
  # ${primary_key} : the value of `replicator_manager.settings.primary_key`
</source>

<match replicator.**>
  @type mysql_replicator_elasticsearch

  # Elasticsearch connection.
  host localhost
  port 9200

  # Derive the Elasticsearch index / type / id from the tag.
  tag_format (?<index_name>[^\.]+)\.(?<type_name>[^\.]+)\.(?<event>[^\.]+)\.(?<primary_key>[^\.]+)$

  <buffer>
    @type              file
    path               /var/log/fluent/buffer/mysql_replicator_elasticsearch
    flush_interval     5s
    flush_at_shutdown  true   # flush queued chunks on shutdown (recommended)
    retry_max_interval 30m    # cap the exponential backoff between retries
  </buffer>
</match>
`````

> Using the [fluent-package](https://www.fluentd.org/download/fluent_package)
> distribution? Its buffer/log directory is `/var/log/fluent/` (the old td-agent
> path was `/var/log/td-agent/`).
