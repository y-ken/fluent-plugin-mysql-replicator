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

## Tutorial

#### configuration

`````
<source>
  type mysql_replicator
  host localhost
  username your_mysql_user
  password your_mysql_password
  database myweb
  interval 5s
  tag replicator
  query SELECT id, text from search_test
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
2013-11-25 18:22:25 +0900 replicator.insert: {"id":"1","text":"aaa"}
2013-11-25 18:22:35 +0900 replicator.update: {"id":"1","text":"bbb"}
2013-11-25 18:22:45 +0900 replicator.delete: {"id":"1"}
`````

## Performance

On syncing 300 million rows table, it will consume around 800MB of memory with ruby 1.9.3 environment.

## TODO

Pull requests are very welcome!!

## Copyright

Copyright © 2013- Kentaro Yoshida ([@yoshi_ken](https://twitter.com/yoshi_ken))

## License

Apache License, Version 2.0
