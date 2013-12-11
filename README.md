# fluent-plugin-mysql-replicator [![Build Status](https://travis-ci.org/y-ken/fluent-plugin-mysql-replicator.png?branch=master)](https://travis-ci.org/y-ken/fluent-plugin-mysql-replicator)

## Overview

Fluentd input plugin to track insert/update/delete event from MySQL database server.

## Installation

`````
### native gem
gem install fluent-plugin-mysql-replicator

### td-agent gem
/usr/lib64/fluent/ruby/bin/fluent-gem install fluent-plugin-mysql-replicator
`````

## Tutorial for Quickstart

It is useful for these purpose.

* try it on this plugin.
* replicate small record under a millons table.

**Note:**  
On syncing 300 million rows table, it will consume around 800MB of memory with ruby 1.9.3 environment.

#### configuration

`````
<source>
  type mysql_replicator

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

<match replicator.*>
  type stdout
</match>
`````

#### sample query

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

#### result

`````
$ tail -f /var/log/td-agent/td-agent.log
2013-11-25 18:22:25 +0900 replicator.insert.id: {"id":"1","text":"aaa"}
2013-11-25 18:22:35 +0900 replicator.update.id: {"id":"1","text":"bbb"}
2013-11-25 18:22:45 +0900 replicator.delete.id: {"id":"1"}
`````

## Tutorial for Production

It is very useful to replicate a millions of records and/or multiple tables with multiple threads.  
This architecture is storing hash table in mysql management table instead of ruby internal memory.  

**Note:**  
On syncing 300 million rows table, it will consume around 20MB of memory with ruby 1.9.3 environment.

#### prepare

* create database and tables.
* add replicator configuration.

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
  `primary_key` varchar(11) DEFAULT 'id',
  `enable_delete` int(11) DEFAULT '1',
  PRIMARY KEY (`id`),
  UNIQUE KEY `name` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
```

```
$ mysql
mysql> source /path/to/setup_mysql_replicator_multi.sql
mysql> insert into source ...snip...;
```

#### configuration

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
  type stdout
</match>
`````

## TODO

Pull requests are very welcome like below!!

* more tests.
* support string type of primary_key.
* support reload setting on demand.

## Copyright

Copyright © 2013- Kentaro Yoshida ([@yoshi_ken](https://twitter.com/yoshi_ken))

## License

Apache License, Version 2.0
