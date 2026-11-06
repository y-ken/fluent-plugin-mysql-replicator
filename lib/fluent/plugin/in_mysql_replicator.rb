require 'mysql2'
require 'digest/sha1'
require 'json'
require 'fluent/plugin/input'
require_relative 'mysql_replicator_nested_query'

module Fluent::Plugin
  class MysqlReplicatorInput < Fluent::Plugin::Input
    Fluent::Plugin.register_input('mysql_replicator', self)

    helpers :thread
    include MysqlReplicatorNestedQuery

    # prepared_query failed, or its connection could not be opened. It holds only the error number and the SQLSTATE: the
    # message of MySQL can hold values of the rows.
    class PreparedQueryError < StandardError
      attr_reader :errno, :sql_state

      def initialize(error)
        @errno = error.respond_to?(:error_number) ? error.error_number : nil
        @sql_state = error.respond_to?(:sql_state) ? error.sql_state : nil
        super("prepared_query failed. :errno=>#{@errno} :sql_state=>#{@sql_state}")
      end
    end

    config_param :host, :string, :default => 'localhost'
    config_param :port, :integer, :default => 3306
    config_param :username, :string, :default => 'root'
    config_param :password, :string, :default => nil, :secret => true
    config_param :database, :string, :default => nil
    config_param :encoding, :string, :default => 'utf8'
    config_param :query, :string
    config_param :prepared_query, :string, :default => nil
    # A single column name, or a comma-separated list for a composite key
    # (e.g. "tenant_id,id"). The id used for change detection and the
    # Elasticsearch document _id is the combination of these columns.
    config_param :primary_key, :array, :default => ['id']
    config_param :interval, :string, :default => '1m'
    config_param :enable_delete, :bool, :default => true
    # Comma-separated column names whose MySQL JSON values should be parsed into
    # nested objects before emitting. Intended for Elasticsearch; do not set it
    # when the destination cannot store JSON objects (e.g. Solr).
    config_param :json_columns, :array, :default => []
    config_param :tag, :string, :default => nil

    def configure(conf)
      super
      @interval = Fluent::Config.time_value(@interval)

      if @tag.nil?
        raise Fluent::ConfigError, "mysql_replicator: missing 'tag' parameter. Please add following line into config like 'tag replicator.mydatabase.mytable.${event}.${primary_key}'"
      end

      log.info "adding mysql_replicator worker. :tag=>#{tag} :query=>#{@query} :prepared_query=>#{@prepared_query} :interval=>#{@interval}sec :enable_delete=>#{enable_delete} :json_columns=>#{@json_columns}"
    end

    def start
      super
      thread_create(:in_mysql_replicator_runner, &method(:run))
    end

    def shutdown
     super
    end

    def run
      begin
        poll
      rescue StandardError => e
        log.error "mysql_replicator: failed to execute query."
        log.error "error: #{e.message}"
        log.error e.backtrace.join("\n")
      end
    end

    def poll
      @table_hash = Hash.new
      @ids = Array.new
      loop do
        poll_once
        sleep @interval
      end
    end

    # Runs the query once, and emits the inserted, updated and deleted rows since the previous run.
    def poll_once
      rows_count = 0
      skipped_count = 0
      failed_nested_queries = Hash.new(0)
      start_time = Time.now
      previous_ids = @ids
      current_ids = Array.new
      # Kept for a poll that prepared_query fails.
      baseline = @table_hash.dup unless @prepared_query.nil?
      # The nested queries run on this connection, so that they see the session that prepared_query sets up. It is a
      # new session for each poll, as a session cannot create the same temporary table twice.
      @prepared_con = open_prepared_connection if !@prepared_query.nil?
      rows, @con = query(@query, @con)
      rows.each do |row|
        id = extract_id(row)
        # A row without its primary key cannot be tracked, so it is skipped. Stopping here instead would leave the
        # rows after it out of current_ids, and they would be sent as deleted.
        if id.any?(&:nil?)
          skipped_count += 1
          next
        end
        current_ids << id
        row.each {|k, v| row[k] = v.to_s if v.is_a?(Time) || v.is_a?(Date) || v.is_a?(BigDecimal)}
        parse_json_columns!(row, @json_columns)
        begin
          row.select {|k, v| nested_query_value?(v) }.each do |k, v|
            row[k] = [] unless row[k].is_a?(Array)
            run_nested_query(k, v, row).each do |nest_row|
              nest_row.each {|k, v| nest_row[k] = v.to_s if v.is_a?(Time) || v.is_a?(Date) || v.is_a?(BigDecimal)}
              row[k] << nest_row
            end
          end
        rescue MysqlReplicatorNestedQuery::SqlError => e
          # The row is held back for this poll: it is not sent, and its id and hash are kept, so that it is not taken
          # as deleted, and it is sent once its nested query works. Sending it without the rows of the nested query
          # would overwrite them downstream.
          failed_nested_queries[e.message] += 1
          next
        end
        current_hash = row_hash(row)
        if !@table_hash.include?(id)
          tag = format_tag(@tag, {:event => :insert})
          emit_record(tag, row)
        elsif @table_hash[id] != current_hash
          tag = format_tag(@tag, {:event => :update})
          emit_record(tag, row)
        end
        @table_hash[id] = current_hash
        rows_count += 1
      end
      if skipped_count > 0
        log.error "mysql_replicator: skipped #{skipped_count} rows without the primary key. :tag=>#{tag} :primary_key=>#{@primary_key.join(',')}"
      end
      # One line for each poll, without the values of the rows: the message of MySQL quotes the query, which has them.
      failed_nested_queries.each do |message, count|
        log.error "mysql_replicator: held back #{count} rows in this poll, as #{message}. :tag=>#{tag}"
      end
      # An empty result does not delete every row (see detect_deleted_ids). Keep the previous ids as the baseline, so
      # that the rows that do not come back are deleted when the query returns rows again.
      @ids = current_ids unless current_ids.empty?
      if @enable_delete
        deleted_ids = detect_deleted_ids(previous_ids, current_ids)
        if deleted_ids.count > 0
          hash_delete_by_list(@table_hash, deleted_ids)
          deleted_ids.each do |id|
            tag = format_tag(@tag, {:event => :delete})
            emit_record(tag, Hash[@primary_key.zip(id)])
          end
        end
      end
      elapsed_time = sprintf("%0.02f", Time.now - start_time)
      log.info "mysql_replicator: finished execution :tag=>#{tag} :rows_count=>#{rows_count} :elapsed_time=>#{elapsed_time} sec"
    rescue PreparedQueryError => e
      # The poll is skipped: no deletes, and the ids and hashes of the previous poll stay, so that the next poll, on a new
      # connection after the interval, compares with them. A row that this poll sent before prepared_query failed again
      # (on a connection opened again in the middle of the poll) is sent again by the next poll.
      @table_hash = baseline
      log.error "mysql_replicator: prepared_query failed; skipped this poll. :tag=>#{@tag} :errno=>#{e.errno} :sql_state=>#{e.sql_state}"
    ensure
      @con.close if @con
      @prepared_con.close if @prepared_con
      @prepared_con = nil
    end

    # The hash that tells whether a row changed. It is taken after the nested queries, so that a change in their rows is
    # an update, and from Marshal, which tells nil from "" and keeps the column boundaries.
    def row_hash(row)
      Digest::SHA1.hexdigest(Marshal.dump(row))
    end

    # Runs the nested query of a column for a row on @prepared_con, which has the session of prepared_query, and returns
    # its rows. The values are escaped on the same connection, so that they follow its character set and sql_mode
    # (prepared_query can set NO_BACKSLASH_ESCAPES). A connection that is lost is closed and opened again with
    # prepared_query. A connection error is retried, like the main query. An error in the SQL, such as a syntax error
    # or an unknown column, would fail the same way on every try, so it raises SqlError.
    def run_nested_query(column, template, row)
      reopened = false
      begin
        if @prepared_con.nil? || !@prepared_con.ping
          @prepared_con.close if @prepared_con
          @prepared_con = @prepared_query.nil? ? get_connection : open_prepared_connection
        end
        @prepared_con.query(expand_nested_query(template, row, @prepared_con)).to_a
      rescue PreparedQueryError
        raise
      rescue Exception => e
        raise MysqlReplicatorNestedQuery::SqlError.new(column, e) if sql_error?(e)
        # As in query(): a connection that was lost is opened again at once the first time.
        if !reopened && @prepared_con && !@prepared_con.ping
          reopened = true
          retry
        end
        log.warn "mysql_replicator: #{e}"
        sleep @interval
        retry
      end
    end

    # Opens a connection and runs the statements of prepared_query on it. The results of a statement, such as a SELECT
    # that sets a user variable or a CALL of a procedure that returns rows, are read out: the connection streams its
    # results, and one left unread makes the next query on it fail. A failure to connect or of a statement, including a
    # CALL that fails after its rows, closes the connection and raises PreparedQueryError, without waiting.
    def open_prepared_connection
      con = get_connection(true)
      @prepared_query.to_s.split(/;/).map(&:strip).reject(&:empty?).each do |statement|
        read_out_results(con, con.query(statement))
      end
      con
    rescue Mysql2::Error => e
      con.close if con
      raise PreparedQueryError.new(e)
    rescue Exception
      con.close if con
      raise
    end

    def read_out_results(con, result)
      result.each {} if result
      while con.next_result
        more = con.store_result
        more.each {} if more
      end
    end

    def hash_delete_by_list (hash, deleted_keys)
      deleted_keys.each{|k| hash.delete(k)}
    end

    # A row's id is the array of its primary-key column values, supporting
    # composite keys. It is a single-element array for a single-column key.
    def extract_id(row)
      @primary_key.map {|col| row[col] }
    end

    # Returns the primary keys that disappeared since the previous poll.
    #
    # The first poll only establishes a baseline: there is no previous snapshot
    # to diff against, so nothing is reported as deleted yet. This also avoids
    # the old `[*1...current_ids.max]` range, which raised "bad value for range"
    # for non-integer primary keys and allocated a huge array (and emitted
    # phantom deletes) for large / sparse integer ids. (#42)
    #
    # An empty result is not taken as "every row was deleted", and nothing is reported.
    def detect_deleted_ids(previous_ids, current_ids)
      return [] if previous_ids.empty?
      return [] if current_ids.empty?
      previous_ids - current_ids
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

    def format_tag(tag, param)
      pattern = {'${event}' => param[:event].to_s, '${primary_key}' => @primary_key.join(',')}
      tag.gsub(/(\${[a-z_]+})/) do
        log.warn "mysql_replicator: missing placeholder. :tag=>#{tag} :placeholder=>#{$1}" unless pattern.include?($1)
        pattern[$1]
      end
    end

    # A column value triggers a nested sub-query only when it is a query
    # template containing a `${placeholder}` (e.g. "SELECT ... WHERE x = ${id}").
    # Requiring the placeholder prevents ordinary text values that merely begin
    # with the word "SELECT" from being executed as SQL. (#4; mirrors the fix
    # already applied to mysql_replicator_multi in #6.)
    def nested_query_value?(value)
      value.to_s.strip.match?(/^SELECT[^\$]+\$\{[^\}]+\}/i)
    end

    def emit_record(tag, record)
      router.emit(tag, Fluent::Engine.now, record)
    end

    # Runs a query, and returns its result and the connection it ran on. A connection that is lost is closed and opened
    # again, with the block if one is given (for the session of prepared_query), and the query is tried again after a
    # failure. A PreparedQueryError of the block is not tried again here: it skips the poll, which waits for the interval.
    # A query that failed as its connection was lost is tried again at once on a new connection, the first time, so that
    # a failure of prepared_query on that connection waits for the interval only once; after that, it waits.
    def query(query, con = nil, &open)
      open ||= method(:get_connection)
      reopened = false
      begin
        if con.nil? || !con.ping
          con.close if con
          con = open.call
        end
        return con.query(query), con
      rescue PreparedQueryError
        raise
      rescue Exception => e
        if !reopened && con && !con.ping
          reopened = true
          retry
        end
        log.warn "mysql_replicator: #{e}"
        sleep @interval
        retry
      end
    end

    # A connection for the session of prepared_query (session is true) is not connected again by the client, which would
    # lose the session without an error (ping connects again and returns true), and a failure to connect is raised
    # instead of tried again.
    def get_connection(session = false)
      begin
        return Mysql2::Client.new({
          :host => @host,
          :port => @port,
          :username => @username,
          :password => @password,
          :database => @database,
          :encoding => @encoding,
          :reconnect => !session,
          :stream => true,
          :cache_rows => false
        })
      rescue Exception => e
        raise if session
        log.warn "mysql_replicator: #{e}"
        sleep @interval
        retry
      end
    end
  end
end
