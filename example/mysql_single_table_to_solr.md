## case study

It is a guide to replicate single mysql table to solr.

## configuration

```
<source>
  @type mysql_replicator

  # Set connection settings for replicate source.
  host localhost
  username your_mysql_user
  password your_mysql_password
  database myweb

  # Set replicate query configuration.
  query SELECT id, text, updated_at from search_test;
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

<match replicator.**>
  @type mysql_replicator_solr

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
  # It's sample for td-agent. If you use Yamabiko, replace path from 'td-agent' to 'yamabiko'.
  flush_at_shutdown yes
  buffer_type file
  buffer_path /var/log/td-agent/buffer/mysql_replicator_elasticsearch
</match>
```

When you use default core (won't specify), change the value of `tag_format` like below.  
On this case, the solr url will be set `http://localhost:8983/solr`

```
<match replicator.**>
  @type mysql_replicator_solr

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
  # It's sample for td-agent. If you use Yamabiko, replace path from 'td-agent' to 'yamabiko'.
  flush_at_shutdown yes
  buffer_type file
  buffer_path /var/log/td-agent/buffer/mysql_replicator_solr
</match>
```
