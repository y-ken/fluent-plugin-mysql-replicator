require 'mysql2'
require 'digest/sha1'
require 'json'
require 'fluent/plugin/input'

module Fluent::Plugin
  class MysqlReplicatorInput < Fluent::Plugin::Input
    Fluent::Plugin.register_input('mysql_replicator', self)

    helpers :thread

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
      table_hash = Hash.new
      ids = Array.new
      con = get_connection()
      prepared_con = get_connection()
      loop do
        rows_count = 0
        start_time = Time.now
        previous_ids = ids
        current_ids = Array.new
        if !@prepared_query.nil?
          @prepared_query.split(/;/).each do |query|
            prepared_con.query(query)
          end
        end
        rows, con = query(@query, con)
        rows.each do |row|
          id = extract_id(row)
          current_ids << id
          current_hash = Digest::SHA1.hexdigest(row.flatten.join)
          row.each {|k, v| row[k] = v.to_s if v.is_a?(Time) || v.is_a?(Date) || v.is_a?(BigDecimal)}
          parse_json_columns!(row, @json_columns)
          row.select {|k, v| nested_query_value?(v) }.each do |k, v|
            row[k] = [] unless row[k].is_a?(Array)
            nest_rows, prepared_con = query(v.gsub(/\$\{([^\}]+)\}/, row[$1].to_s), prepared_con)
            nest_rows.each do |nest_row|
              nest_row.each {|k, v| nest_row[k] = v.to_s if v.is_a?(Time) || v.is_a?(Date) || v.is_a?(BigDecimal)}
              row[k] << nest_row
            end
            prepared_con.close
          end
          if id.any?(&:nil?)
            log.error "mysql_replicator: missing primary_key. :tag=>#{tag} :primary_key=>#{@primary_key.join(',')} :id=>#{id}"
            break
          end
          if !table_hash.include?(id)
            tag = format_tag(@tag, {:event => :insert})
            emit_record(tag, row)
          elsif table_hash[id] != current_hash
            tag = format_tag(@tag, {:event => :update})
            emit_record(tag, row)
          end
          table_hash[id] = current_hash
          rows_count += 1
        end
        con.close
        ids = current_ids
        if @enable_delete
          deleted_ids = detect_deleted_ids(previous_ids, current_ids)
          if deleted_ids.count > 0
            hash_delete_by_list(table_hash, deleted_ids)
            deleted_ids.each do |id|
              tag = format_tag(@tag, {:event => :delete})
              emit_record(tag, Hash[@primary_key.zip(id)])
            end
          end
        end
        elapsed_time = sprintf("%0.02f", Time.now - start_time)
        log.info "mysql_replicator: finished execution :tag=>#{tag} :rows_count=>#{rows_count} :elapsed_time=>#{elapsed_time} sec"
        sleep @interval
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

    def query(query, con = nil)
      begin
        con = con.nil? ? get_connection : con
        con = con.ping ? con : get_connection
        return con.query(query), con
      rescue Exception => e
        log.warn "mysql_replicator: #{e}"
        sleep @interval
        retry
      end
    end

    def get_connection
      begin
        return Mysql2::Client.new({
          :host => @host,
          :port => @port,
          :username => @username,
          :password => @password,
          :database => @database,
          :encoding => @encoding,
          :reconnect => true,
          :stream => true,
          :cache_rows => false
        })
      rescue Exception => e
        log.warn "mysql_replicator: #{e}"
        sleep @interval
        retry
      end
    end
  end
end
