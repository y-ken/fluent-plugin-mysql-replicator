require 'fluent/plugin/input'
require_relative 'mysql_replicator_nested_query'

module Fluent::Plugin
  class MysqlReplicatorMultiInput < Fluent::Plugin::Input
    Fluent::Plugin.register_input('mysql_replicator_multi', self)

    helpers :thread
    include MysqlReplicatorNestedQuery

    # The connection of prepared_query was lost in the middle of a poll. It holds only the error number and the SQLSTATE:
    # the message of MySQL can hold values of the rows.
    class PreparedSessionLost < StandardError
      attr_reader :errno, :sql_state

      def initialize(error)
        @errno = error.error_number
        @sql_state = error.sql_state
        super("lost the connection of prepared_query. :errno=>#{@errno} :sql_state=>#{@sql_state}")
      end
    end

    def initialize
      require 'mysql2'
      require 'digest/sha1'
      require 'json'
      super
    end

    config_param :manager_host, :string, :default => 'localhost'
    config_param :manager_port, :integer, :default => 3306
    config_param :manager_username, :string, :default => nil
    config_param :manager_password, :string, :default => '', :secret => true
    config_param :manager_database, :string, :default => 'replicator_manager'
    config_param :tag, :string, :default => nil

    config_param :bulk_insert_count, :integer, :default => 50
    config_param :bulk_insert_timeout, :integer, :default => 10

    def configure(conf)
      super
      if @tag.nil?
        raise Fluent::ConfigError, "mysql_replicator_multi: missing 'tag' parameter. Please add following line into config like 'tag replicator.${name}.${event}.${primary_key}'"
      end
    end

    def start
      super
      begin
        @threads = []
        @mutex = Mutex.new
        @manager_db = get_manager_connection
        @manager_db.query("SET SESSION wait_timeout=1800;")
        @running = true
        # Set up before any thread starts, as a poller can add to the buffer before the flusher thread runs.
        @hash_table_bulk_insert = []
        @hash_table_bulk_insert_last_time = Time.now
        @threads << thread_create(:in_mysql_replicator_flusher) {
          hash_table_flusher
        }
        get_settings.each_with_index do |config, idx|
          @threads << thread_create(:"in_mysql_replicator_pollers_#{idx}") {
            poll(config)
          }
        end
        log.error "mysql_replicator_multi: stop working due to empty configuration" if @threads.empty?
      rescue StandardError => e
        log.error "error: #{e.message}"
        log.error e.backtrace.join("\n")
      end
    end

    def stop
      @running = false
      super
    end

    def shutdown
      @threads.each(&:join)
      super
    end

    def get_settings
      manager_db = get_manager_connection
      manager_db.query("SELECT * FROM settings WHERE is_active = 1;").to_a
    ensure
      manager_db.close if manager_db
    end

    def poll(config)
      begin
        masked_config = Hash[config.map {|k,v| (k == 'password') ? [k, v.to_s.gsub(/./, '*')] : [k,v]}]
        @mutex.synchronize {
          log.info "mysql_replicator_multi: polling start. :config=>#{masked_config}"
        }
        primary_key = config['primary_key']
        json_columns = (config['json_columns'] || '').split(',').map(&:strip).reject(&:empty?)
        previous_id = current_id = nil
        while @running
          previous_id_at_start = previous_id
          rows_count = 0
          skipped_count = 0
          failed_nested_queries = Hash.new(0)
          start_time = Time.now
          db = nil
          nest_db = nil
          begin
            unless config['prepared_query'].nil?
              # The client does not connect again, which would lose the session of prepared_query without an error.
              nest_db = get_origin_connection(config, config['prepared_query'].strip.empty?)
              # A statement that fails, including a CALL that fails after its rows, skips the poll, which is tried
              # again on a new connection after the interval. Only the error number and the SQLSTATE are logged: the
              # message of MySQL can hold values of the rows.
              begin
                run_prepared_query(nest_db, config['prepared_query'])
              rescue Mysql2::Error => e
                nest_db.close
                @mutex.synchronize {
                  log.error "mysql_replicator_multi: prepared_query failed; skipped this poll. :setting_name=>#{config['name']} :errno=>#{e.error_number} :sql_state=>#{e.sql_state}"
                }
                sleep config['interval']
                next
              end
            end
            db = get_origin_connection(config)
            db.query(config['query']).each do |row|
              # A row without its primary key cannot be tracked, so it is skipped. previous_id stays at the row
              # before it, so a row deleted next to it is still detected.
              if row[primary_key].nil?
                skipped_count += 1
                next
              end
              row.each {|k, v| row[k] = v.to_s if v.is_a?(Time) || v.is_a?(Date) || v.is_a?(BigDecimal)}
              parse_json_columns!(row, json_columns)
              held_back = false
              begin
                row.select {|k, v| v.to_s.strip.match(/^SELECT[^\$]+\$\{[^\}]+\}/i) }.each do |k, v|
                  row[k] = [] unless row[k].is_a?(Array)
                  run_nested_query(nest_db, config, k, v, row).each do |nest_row|
                    nest_row.each {|k, v| nest_row[k] = v.to_s if v.is_a?(Time) || v.is_a?(Date) || v.is_a?(BigDecimal)}
                    row[k] << nest_row
                  end
                end
              rescue MysqlReplicatorNestedQuery::SqlError => e
                # The row is held back for this poll: it is not sent and hash_tables keeps its hash, but it still counts
                # as a row of this poll, so that it is not taken as deleted. It is sent once its nested query works.
                # Sending it without the rows of the nested query would overwrite them downstream.
                failed_nested_queries[e.message] += 1
                held_back = true
              end
              current_id = row[primary_key]
              @mutex.synchronize {
                detect_insert_update(config, row) unless held_back
                detect_delete(config, current_id, previous_id)
              }
              previous_id = current_id
              rows_count += 1
            end
          rescue PreparedSessionLost => e
            # The rest of the poll is skipped, as when prepared_query fails. The next poll does not compare its first row
            # with the last row seen here, which would make the rows after it look deleted. If this poll had rows, its
            # first row already did that comparison with the poll before, and the rows that it added to hash_tables would
            # look deleted if it were done again, so the next poll does not compare its first row at all; rows deleted
            # at the end are found at the end of the next poll.
            previous_id = rows_count.zero? ? previous_id_at_start : nil
            db.close if db
            nest_db.close
            @mutex.synchronize {
              log.error "mysql_replicator_multi: lost the connection of prepared_query; skipped the rest of this poll. :setting_name=>#{config['name']} :errno=>#{e.errno} :sql_state=>#{e.sql_state}"
            }
            sleep config['interval']
            next
          rescue Mysql2::Error => e
            raise e unless config['enable_retry'] == 1

            @mutex.synchronize {
              log.error "mysql_replicator_multi: failed due to an error caused by the database. :setting_name=>#{config['name']}"
              log.error "error: #{e.message}"
              log.error e.backtrace.join("\n")
            }
            sleep config['retry_interval']
          ensure
            db.close if db
            nest_db.close if nest_db && !config['prepared_query'].nil?
          end
          if skipped_count > 0
            @mutex.synchronize {
              log.error "mysql_replicator_multi: skipped #{skipped_count} rows without the primary key. :setting_name=>#{config['name']} :primary_key=>#{primary_key}"
            }
          end
          # One line for each poll, without the values of the rows: the message of MySQL quotes the query, which has them.
          failed_nested_queries.each do |message, count|
            @mutex.synchronize {
              log.error "mysql_replicator_multi: held back #{count} rows in this poll, as #{message}. :setting_name=>#{config['name']}"
            }
          end
          elapsed_time = sprintf("%0.02f", Time.now - start_time)
          @mutex.synchronize {
            log.info "mysql_replicator_multi: execution finished. :setting_name=>#{config['name']} :rows_count=>#{rows_count} :elapsed_time=>#{elapsed_time} sec"
          }
          sleep config['interval']
        end
      rescue StandardError => e
        @mutex.synchronize {
          log.error "mysql_replicator_multi: failed to execute query. :config=>#{masked_config}"
          log.error "error: #{e.message}"
          log.error e.backtrace.join("\n")
        }
      end
    end

    # Runs the nested query of a column for a row on nest_db, which has the session of prepared_query, and returns its
    # rows. The values are escaped on the same connection. An error in the SQL, such as a syntax error or an unknown
    # column, would fail the same way on every poll, so it raises SqlError. A lost connection of prepared_query raises
    # PreparedSessionLost (see nest_query). Other errors fail the poll as before (and it is tried again with enable_retry).
    def run_nested_query(nest_db, config, column, template, row)
      nest_query(nest_db, config, expand_nested_query(template, row, nest_db))
    rescue Mysql2::Error => e
      raise unless sql_error?(e)
      raise MysqlReplicatorNestedQuery::SqlError.new(column, e)
    end

    def detect_insert_update(config, row)
      primary_key = config['primary_key']
      current_id = row[primary_key]
      stored_hash = config['enable_loose_insert'] == 1 ? "" : get_stored_hash(config['name'], current_id)
      current_hash = Digest::SHA1.hexdigest(row.flatten.join)

      event = nil
      if stored_hash.empty?
        event = :insert
      elsif stored_hash != current_hash
        event = :update
      end
      unless event.nil?
        tag = format_tag(@tag, {:name => config['name'], :event => event, :primary_key => config['primary_key']})
        emit_record(tag, row)
        update_hashtable({:event => event, :id => current_id, :setting_name => config['name'], :hash => current_hash})
      end
    end

    def get_stored_hash(setting_name, id)
      query = "SELECT SQL_NO_CACHE setting_query_hash FROM hash_tables WHERE setting_query_pk = #{id.to_i} AND setting_name = '#{setting_name}'"
      row = @manager_db.query(query).first
      return row.nil? ? "" : row['setting_query_hash']
    end

    def detect_delete(config, current_id, previous_id)
      return if config['enable_delete'] != 1 || previous_id.nil?
      deleted_ids = collect_gap_ids(config, current_id, previous_id)
      unless deleted_ids.empty?
        event = :delete
        deleted_ids.each do |id|
          tag = format_tag(@tag, {:name => config['name'], :event => event, :primary_key => config['primary_key']})
          emit_record(tag, {config['primary_key'] => id})
        end
        update_hashtable({:event =>  event, :ids => deleted_ids, :setting_name => config['name']})
      end
    end

    def collect_gap_ids(config, current_id, previous_id)
      setting_name = config['name']
      if (current_id - previous_id) > 1 && config['enable_loose_delete'] == 0
        query = "SELECT SQL_NO_CACHE setting_query_pk FROM hash_tables
          WHERE setting_name = '#{setting_name}'
          AND setting_query_pk > #{previous_id.to_i} AND setting_query_pk < #{current_id.to_i}"
      elsif (current_id - previous_id) > 1 && config['enable_loose_delete'] == 1
        return [*previous_id...current_id] - [current_id,previous_id]
      elsif previous_id > current_id
        query = "SELECT SQL_NO_CACHE setting_query_pk FROM hash_tables
          WHERE setting_name = '#{setting_name}'
          AND setting_query_pk > #{previous_id.to_i}"
      elsif previous_id == current_id
        query = "SELECT SQL_NO_CACHE setting_query_pk FROM hash_tables
          WHERE setting_name = '#{setting_name}'
          AND (setting_query_pk > #{current_id.to_i} OR setting_query_pk < #{current_id.to_i})"
      end
      ids = Array.new
      unless query.nil?
        @manager_db.query(query).each do |row|
          ids << row['setting_query_pk']
        end
      end
      return ids
    end

    def update_hashtable(opts)
      case opts[:event]
      when :insert
        add_hash_table_buffer(opts[:setting_name], opts[:id], opts[:hash])
      when :update
        query = "UPDATE hash_tables SET setting_query_hash = '#{opts[:hash]}' WHERE setting_name = '#{opts[:setting_name]}' AND setting_query_pk = '#{opts[:id]}'"
      when :delete
        query = "DELETE FROM hash_tables WHERE setting_name = '#{opts[:setting_name]}' AND setting_query_pk IN(#{opts[:ids].join(',')})"
      end
      @manager_db.query(query) unless query.nil?
    end

    def format_tag(tag, param)
      pattern = {'${name}' => param[:name], '${event}' => param[:event].to_s, '${primary_key}' => param[:primary_key]}
      tag.gsub(/(\${[a-z_]+})/) do
        log.warn "mysql_replicator_multi: unknown placeholder found. :tag=>#{tag} :placeholder=>#{$1}" unless pattern.include?($1)
        pattern[$1]
      end
    end

    def add_hash_table_buffer(setting_name, id, hash)
      @hash_table_bulk_insert << "('#{setting_name}','#{id}','#{hash}')"
      flush_hash_table if @hash_table_bulk_insert.size >= @bulk_insert_count
    end

    def hash_table_flusher
      while @running
        if @hash_table_bulk_insert.empty? || @bulk_insert_timeout > (Time.now - @hash_table_bulk_insert_last_time)
          sleep @bulk_insert_timeout
          next
        end
        sleep @bulk_insert_timeout unless flush_hash_table_safely
      end
      flush_hash_table_safely
    end

    # A failed flush, such as a timeout of the manager database, is logged, and the buffer stays for the next flush.
    # Returns whether the flush succeeded.
    def flush_hash_table_safely
      @mutex.synchronize { flush_hash_table }
      true
    rescue StandardError => e
      @mutex.synchronize {
        log.error "mysql_replicator_multi: failed to flush buffered query."
        log.error "error: #{e.message}"
        log.error e.backtrace.join("\n")
      }
      false
    end

    def flush_hash_table
      return if @hash_table_bulk_insert.empty?
      begin
        @manager_db.query(hash_table_insert_query(@hash_table_bulk_insert))
      rescue Mysql2::Error => e
        raise unless hash_table_cannot_hold?(e)
        write_hash_table_rows_one_by_one(e)
      end
      @hash_table_bulk_insert.clear
      @hash_table_bulk_insert_last_time = Time.now
    end

    def hash_table_insert_query(values)
      "INSERT INTO hash_tables (setting_name,setting_query_pk,setting_query_hash)
        VALUES #{values.join(',')}
        ON DUPLICATE KEY UPDATE setting_query_hash = VALUES(setting_query_hash)"
    end

    # A row that hash_tables cannot hold, such as a primary key out of the range of setting_query_pk (INT) or one that is
    # not a number, fails the whole statement, and would fail it on every flush, so that the rows of every setting
    # stay out of hash_tables. The rows are then written one by one, and the ones that fail that way are dropped.
    # They are sent as inserts again on each poll. A failure of another kind keeps the buffer for the next flush.
    def write_hash_table_rows_one_by_one(error)
      dropped = @hash_table_bulk_insert.count do |value|
        begin
          @manager_db.query(hash_table_insert_query([value]))
          false
        rescue Mysql2::Error => e
          raise unless hash_table_cannot_hold?(e)
          true
        end
      end
      # Without the message of MySQL, which can quote the value.
      log.error "mysql_replicator_multi: dropped #{dropped} rows that hash_tables cannot hold, with MySQL error #{error.error_number} (SQLSTATE #{error.sql_state}); they are sent as inserts again on each poll. Check that setting_query_pk can hold the primary keys of the settings."
    end

    # Errors in the data or the SQL (SQLSTATE class 22, 23, 21 or 42), "Data truncated" (1265, 01000), as for '12abc' or
    # a date, and "Incorrect integer value" (1366, HY000).
    def hash_table_cannot_hold?(error)
      error.sql_state.to_s.start_with?('22', '23', '21', '42') || [1265, 1366].include?(error.error_number)
    end

    # Parse the given columns' JSON string values into nested objects in place.
    # Non-string values, missing columns, and malformed JSON are left untouched
    # so enabling this never corrupts non-JSON data.
    def parse_json_columns!(row, columns)
      return if columns.empty?
      columns.each do |col|
        v = row[col]
        next unless v.is_a?(String)
        begin
          row[col] = JSON.parse(v)
        rescue JSON::ParserError
          # leave the original string as-is on malformed JSON
        end
      end
    end

    def emit_record(tag, record)
      router.emit(tag, Fluent::Engine.now, record)
    end

    def get_manager_connection
      begin
        return Mysql2::Client.new(
          :host => @manager_host,
          :port => @manager_port,
          :username => @manager_username,
          :password => @manager_password,
          :database => @manager_database,
          :encoding => 'utf8',
          :reconnect => true,
          :stream => false,
          :cache_rows => false
        )
      rescue Mysql2::Error => e
        raise "mysql_replicator_multi: #{e}"
      end
    end

    # Runs a nested query on nest_db and reads its rows. With prepared_query, nest_db does not connect again, so a lost
    # connection, also while the rows are read, raises PreparedSessionLost; connecting again would run the rest of the
    # poll without the session.
    def nest_query(nest_db, config, query)
      nest_db.query(query).to_a
    rescue Mysql2::Error => e
      raise if config['prepared_query'].to_s.strip.empty? || nest_db.ping
      raise PreparedSessionLost.new(e)
    end

    # The results of a statement, such as a SELECT that sets a user variable or a CALL of a procedure that returns rows,
    # are read out: the connection streams its results, and one left unread makes the next query on it fail.
    def run_prepared_query(db, prepared_query)
      prepared_query.split(/;/).map(&:strip).reject(&:empty?).each do |query|
        result = db.query(query)
        result.each {} if result
        while db.next_result
          more = db.store_result
          more.each {} if more
        end
      end
    end

    def get_origin_connection(config, reconnect = true)
      begin
        return Mysql2::Client.new(
          :host => config['host'],
          :port => config['port'],
          :username => config['username'],
          :password => config['password'],
          :database => config['database'],
          :encoding => 'utf8',
          :reconnect => reconnect,
          :stream => true,
          :cache_rows => false
        )
      rescue Mysql2::Error => e
        if config['enable_retry'] == 1
          raise e
        else
          raise "mysql_replicator_multi: #{e}"
        end
      end
    end
  end
end
