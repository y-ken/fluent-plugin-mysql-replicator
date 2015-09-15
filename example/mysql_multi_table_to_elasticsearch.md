## case study

It is a guide to replicate multiple mysql table to elasticsearch.

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
  type mysql_replicator_elasticsearch

  # Set Elasticsearch connection.
  host localhost
  port 9200

  # You can configure to use SSL for connecting to Elasticsearch.
  # ssl true

  # Basic authentication credentials can be configured
  # username basic_auth_username
  # password basic_auth_password

  # Set Elasticsearch index, type, and unique id (primary_key) from tag.
  tag_format (?<index_name>[^\.]+)\.(?<type_name>[^\.]+)\.(?<event>[^\.]+)\.(?<primary_key>[^\.]+)$

  # Set frequency of sending bulk request to Elasticsearch node.
  flush_interval 5s

  # Set maximum retry interval (required fluentd >= 0.10.41)
  max_retry_wait 1800

  # Queued chunks are flushed at shutdown process.
  # It's sample for td-agent. If you use Yamabiko, replace path from 'td-agent' to 'yamabiko'.
  flush_at_shutdown yes
  buffer_type file
  buffer_path /var/log/td-agent/buffer/mysql_replicator_elasticsearch
</match>
```
