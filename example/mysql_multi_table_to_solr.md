## case study

It is a guide to replicate multiple mysql table to solr.

## configuration

```
<source>
  type mysql_replicator_multi

  # Database connection setting for manager table.
  manager_host localhost
  manager_username your_mysql_user
  manager_password your_mysql_password
  manager_database replicator_manager

  # Format output tag for each events. Placeholders usage as described below.
  tag replicator.${name}.${event}.${primary_key}
  # ${name} : the value of `replicator_manager.settings.name` in manager table.
  # ${event} : the variation of row event type by insert/update/delete.
  # ${primary_key} : the value of `replicator_manager.settings.primary_key` in manager table.
</source>

<match replicator.**>
  type mysql_replicator_solr

  # Set Solr connection.
  host localhost
  port 8983

  # Set Solr core name and unique id (primary_key) from tag.
  # On this case, solr url will be http://localhost:8983/solr/${core_name}
  tag_format (?<core_name>[^\.]+)\.(?<event>[^\.]+)\.(?<primary_key>[^\.]+)$

  # Set frequency of sending bulk request to Solr.
  flush_interval 5s

  # Set maximum retry interval (required fluentd >= 0.10.41)
  max_retry_wait 1800

  # Queued chunks are flushed at shutdown process.
  flush_at_shutdown yes
</match>
```

When you use default core (won't specify), change the value of `tag_format` like below.

```
<match replicator.**>
  type mysql_replicator_solr

  # Set Solr connection.
  host localhost
  port 8983

  # Set Solr core name and unique id (primary_key) from tag.
  # On this case, solr url will be http://localhost:8983/solr/
  tag_format (?<event>[^\.]+)\.(?<primary_key>[^\.]+)$

  # Set frequency of sending bulk request to Solr.
  flush_interval 5s

  # Set maximum retry interval (required fluentd >= 0.10.41)
  max_retry_wait 1800

  # Queued chunks are flushed at shutdown process.
  flush_at_shutdown yes
</match>
```