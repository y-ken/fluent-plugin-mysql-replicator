CREATE DATABASE replicator_manager;
USE replicator_manager;

CREATE TABLE `hashmap` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `source_name` varchar(255) NOT NULL,
  `source_query_pk` int(11) NOT NULL,
  `source_query_hash` varchar(255) NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `source_query_pk` (`source_query_pk`,`source_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE `source` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `host` varchar(255) NOT NULL DEFAULT 'localhost',
  `port` int(11) NOT NULL DEFAULT '3306',
  `username` varchar(255) NOT NULL,
  `password` varchar(255) NOT NULL,
  `database` varchar(255) NOT NULL,
  `query` TEXT NOT NULL,
  `interval` int(11) NOT NULL,
  `tag` varchar(255) NOT NULL,
  `primary_key` varchar(11) DEFAULT 'id',
  `enable_delete` int(11) DEFAULT '1',
  PRIMARY KEY (`id`),
  UNIQUE KEY `name` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
