CREATE DATABASE IF NOT EXISTS replicator_manager;
USE replicator_manager;

CREATE TABLE IF NOT EXISTS `hash_tables` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `setting_name` varchar(255) NOT NULL,
  `setting_query_pk` int(11) NOT NULL,
  `setting_query_hash` varchar(255) NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `setting_query_pk` (`setting_query_pk`,`setting_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `settings` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `is_active` int(11) NOT NULL DEFAULT '1',
  `name` varchar(255) NOT NULL,
  `host` varchar(255) NOT NULL DEFAULT 'localhost',
  `port` int(11) NOT NULL DEFAULT '3306',
  `username` varchar(255) NOT NULL,
  `password` varchar(255) NOT NULL,
  `database` varchar(255) NOT NULL,
  `query` TEXT NOT NULL,
  -- Use this field to pre execute query (TEMPORARY TABLE) for improving performance of generating nestd document.
  `prepared_query` TEXT NOT NULL,
  `interval` int(11) NOT NULL,
  `primary_key` varchar(255) DEFAULT 'id',
  `enable_delete` int(11) DEFAULT '1',
  -- On enabling 'enable_loose_insert: 1', make it faster synchronization to skip checking hash_tables.
  `enable_loose_insert` int(11) DEFAULT '0',
  -- On enabling 'enable_loose_delete: 1', turn on speculative delete but performance penalty on non-contiguous primary key.
  `enable_loose_delete` int(11) DEFAULT '0',
  -- On enabling 'enable_retry: 1', automatically retries when an error occurs due to MySQL.
  `enable_retry` int(11) DEFAULT '1',
  -- Additional interval when retrying. If not set, waits for the time set in the regular interval column.
  `retry_interval` int(11) NOT NULL DEFAULT '30',
  PRIMARY KEY (`id`),
  UNIQUE KEY `name` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
