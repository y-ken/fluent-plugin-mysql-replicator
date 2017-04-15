require 'fluent/input'

module Fluent
  class MysqlReplicatorInput < Fluent::Input
    Plugin.register_input('mysql_replicator', self)

    def initialize
      require 'mysql2'
      require 'digest/sha1'
      super
    end

    config_param :host, :string, :default => 'localhost'
    config_param :port, :integer, :default => 3306
    config_param :username, :string, :default => 'root'
    config_param :password, :string, :default => nil, :secret => true
    config_param :database, :string, :default => nil
    config_param :encoding, :string, :default => 'utf8'
    config_param :query, :string
    config_param :prepared_query, :string, :default => nil
    config_param :primary_key, :string, :default => 'id'
    config_param :interval, :string, :default => '1m'
    config_param :enable_delete, :bool, :default => true
    config_param :tag, :string, :default => nil

    def configure(conf)
      super
      @interval = Config.time_value(@interval)

      if @tag.nil?
        raise Fluent::ConfigError, "mysql_replicator: missing 'tag' parameter. Please add following line into config like 'tag replicator.mydatabase.mytable.${event}.${primary_key}'"
      end

      log.info "adding mysql_replicator worker. :tag=>#{tag} :query=>#{@query} :prepared_query=>#{@prepared_query} :interval=>#{@interval}sec :enable_delete=>#{enable_delete}"
    end

    def start
      @thread = Thread.new(&method(:run))
    end

    def shutdown
      Thread.kill(@thread)
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
          current_ids << row[@primary_key]
          current_hash = Digest::SHA1.hexdigest(row.flatten.join)
          row.each {|k, v| row[k] = v.to_s if v.is_a?(Time) || v.is_a?(Date) || v.is_a?(BigDecimal)}
          row.select {|k, v| v.to_s.strip.match(/^SELECT/i) }.each do |k, v|
            row[k] = [] unless row[k].is_a?(Array)
            nest_rows, prepared_con = query(v.gsub(/\$\{([^\}]+)\}/, row[$1].to_s), prepared_con)
            nest_rows.each do |nest_row|
              nest_row.each {|k, v| nest_row[k] = v.to_s if v.is_a?(Time) || v.is_a?(Date) || v.is_a?(BigDecimal)}
              row[k] << nest_row
            end
            prepared_con.close
          end
          if row[@primary_key].nil?
            log.error "mysql_replicator: missing primary_key. :tag=>#{tag} :primary_key=>#{primary_key}"
            break
          end
          if !table_hash.include?(row[@primary_key])
            tag = format_tag(@tag, {:event => :insert})
            emit_record(tag, row)
          elsif table_hash[row[@primary_key]] != current_hash
            tag = format_tag(@tag, {:event => :update})
            emit_record(tag, row)
          end
          table_hash[row[@primary_key]] = current_hash
          rows_count += 1
        end
        con.close
        ids = current_ids
        if @enable_delete
          if current_ids.empty?
            deleted_ids = Array.new
          elsif previous_ids.empty?
            deleted_ids = [*1...current_ids.max] - current_ids
          else
            deleted_ids = previous_ids - current_ids
          end
          if deleted_ids.count > 0
            hash_delete_by_list(table_hash, deleted_ids)
            deleted_ids.each do |id| 
              tag = format_tag(@tag, {:event => :delete})
              emit_record(tag, {@primary_key => id})
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

    def format_tag(tag, param)
      pattern = {'${event}' => param[:event].to_s, '${primary_key}' => @primary_key}
      tag.gsub(/(\${[a-z_]+})/) do
        log.warn "mysql_replicator: missing placeholder. :tag=>#{tag} :placeholder=>#{$1}" unless pattern.include?($1)
        pattern[$1]
      end
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
