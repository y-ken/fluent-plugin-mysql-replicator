## Tutorial for Production (mysql_replicator_multi)

It is very useful to replicate a millions of records and/or multiple tables with multiple threads.  
This architecture is storing hash table in mysql management table instead of ruby internal memory.  

**Note:**  
On syncing 300 million rows table, it will consume around 20MB of memory with ruby 1.9.3 environment.

### prepare

It has done with follwing two steps.

* create database and tables.
* add replicator configuration.

##### create database and tables.

```
$ cat setup_mysql_replicator_multi.sql
CREATE DATABASE replicator_manager;
USE replicator_manager;

CREATE TABLE `hash_tables` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `setting_name` varchar(255) NOT NULL,
  `setting_query_pk` int(11) NOT NULL,
  `setting_query_hash` varchar(255) NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `setting_query_pk` (`setting_query_pk`,`setting_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE `settings` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `is_active` int(11) NOT NULL DEFAULT '1',
  `name` varchar(255) NOT NULL,
  `host` varchar(255) NOT NULL DEFAULT 'localhost',
  `port` int(11) NOT NULL DEFAULT '3306',
  `username` varchar(255) NOT NULL,
  `password` varchar(255) NOT NULL,
  `database` varchar(255) NOT NULL,
  `query` TEXT NOT NULL,
  `interval` int(11) NOT NULL,
  `primary_key` varchar(255) DEFAULT 'id',
  `enable_delete` int(11) DEFAULT '1',
  -- On enabling 'enable_loose_insert: 1', make it faster synchronization to skip checking hash_tables.
  `enable_loose_insert` int(11) DEFAULT '0',
  -- On enabling 'enable_loose_delete: 1', turn on speculative delete but performance penalty on non-contiguous primary key.
  `enable_loose_delete` int(11) DEFAULT '0',
  PRIMARY KEY (`id`),
  UNIQUE KEY `name` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
```

##### add replicator configuration.

```
$ mysql -umysqluser -p

-- For the first time, load schema.
mysql> source /path/to/setup_mysql_replicator_multi.sql

-- Add replicate source connection and query settings like below.
mysql> INSERT INTO `settings`
  (`id`, `is_active`, `name`, `host`, `port`, `username`, `password`, `database`, `query`, `interval`, `primary_key`, `enable_delete`)
VALUES
  (NULL, 1, 'mydb.mytable', '192.168.100.221', 3306, 'mysqluser', 'mysqlpassword', 'mydb', 'SELECT id, text from mytable;', 5, 'id', 1);
```

it is a sample which you have inserted row.

| id | is_active |     name     |      host       | port | username  |   password    | database |            query             | interval | primary_key | enable_delete | enable_loose_insert | enable_loose_delete |
|----|-----------|--------------|-----------------|------|-----------|---------------|----------|------------------------------|----------|-------------|---------------|----|----|
|  1 |         1 | mydb.mytable | 192.168.100.221 | 3306 | mysqluser | mysqlpassword | mydb     | SELECT id, text from mytable; |       5 | id          |             1 |  0 | 0 |

### configuration

`````
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

  # Set Elasticsearch index, type, and unique id (primary_key) from tag.
  tag_format (?<index_name>[^\.]+)\.(?<type_name>[^\.]+)\.(?<event>[^\.]+)\.(?<primary_key>[^\.]+)$

  # Set frequency of sending bulk request to Elasticsearch node.
  flush_interval 5s

  # Set maximum retry interval (required fluentd >= 0.10.41)
  max_retry_wait 1800

  # Queued chunks are flushed at shutdown process.
  flush_at_shutdown yes
</match>
`````
