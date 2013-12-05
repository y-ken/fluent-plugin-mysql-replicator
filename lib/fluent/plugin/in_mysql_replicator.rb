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
    config_param :password, :string, :default => nil
    config_param :database, :string, :default => nil
    config_param :encoding, :string, :default => 'utf8'
    config_param :interval, :string, :default => '1m'
    config_param :tag, :string
    config_param :query, :string
    config_param :primary_key, :string, :default => 'id'

    def configure(conf)
      super
      @interval = Config.time_value(@interval)
      $log.info "adding mysql_replicator job: [#{@query}] interval: #{@interval}sec"
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
        $log.error "error: #{e.message}"
        $log.error e.backtrace.join("\n")
      end
    end

    def poll
      table_hash = Hash.new
      ids = Array.new
      loop do
        previous_ids = ids
        current_ids = Array.new
        query(@query).each do |row|
          current_ids << row[@primary_key]
          current_hash = Digest::SHA1.hexdigest(row.flatten.join)
          if !table_hash.include?(row[@primary_key])
            emit_record(:insert, row)
          elsif table_hash[row[@primary_key]] != current_hash
            emit_record(:update, row)
          end
          table_hash[row[@primary_key]] = current_hash
        end
        ids = current_ids
        deleted_ids = previous_ids - current_ids
        if deleted_ids.count > 0
          hash_delete_by_list(table_hash, deleted_ids)
          deleted_ids.each {|id| emit_record(:delete, {@primary_key => id})}
        end
        sleep @interval        
      end
    end

    def hash_delete_by_list (hash, deleted_keys)
      deleted_keys.each{|k| hash.delete(k)}
    end

    def emit_record(type, record)
      tag = "#{@tag}.#{type.to_s}"
      Engine.emit(tag, Engine.now, record)
    end

    def query(query)
      @mysql ||= get_connection
      begin
        return @mysql.query(query, :cast => false, :cache_rows => false)
      rescue Exception => e
        $log.warn "mysql_replicator: #{e}"
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
        $log.warn "mysql_replicator: #{e}"
        sleep @interval
        retry
      end
    end
  end
end
