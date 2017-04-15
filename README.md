# fluent-plugin-mysql-replicator [![Build Status](https://travis-ci.org/y-ken/fluent-plugin-mysql-replicator.png?branch=master)](https://travis-ci.org/y-ken/fluent-plugin-mysql-replicator)

## Overview

Fluentd input plugin to track insert/update/delete event from MySQL database server.  
Not only that, it could multiple table replication into single or multi Elasticsearch/Solr.  
It's comming support replicate to another RDB/noSQL.

## Requirements

| fluent-plugin-mysql-replicator | fluentd    | ruby   |
|--------------------|------------|--------|
|  0.6.0            | v0.14.x | >= 2.1 |
|  0.6.0            | v0.12.x | >= 1.9 |

## Installation

install with gem or fluent-gem command as:

`````
# for system installed fluentd
$ gem install fluent-plugin-mysql-replicator

# for td-agent2
$ sudo td-agent-gem install fluent-plugin-mysql-replicator -v 0.6.0
`````

## Included plugins

* Input Plugin: mysql_replicator
* Input Plugin: mysql_replicator_multi
* Output Plugin: mysql_replicator_elasticsearch
* Output Plugin: mysql_replicator_solr (experimental)

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
