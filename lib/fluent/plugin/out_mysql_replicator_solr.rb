require 'rsolr'

class Fluent::MysqlReplicatorSolrOutput < Fluent::BufferedOutput
  Fluent::Plugin.register_output('mysql_replicator_solr', self)

  config_param :host, :string,  :default => 'localhost'
  config_param :port, :integer, :default => 8983
  config_param :tag_format, :string, :default => nil

  DEFAULT_TAG_FORMAT = /(?<core_name>[^\.]+)\.(?<event>[^\.]+)\.(?<primary_key>[^\.]+)$/

  def initialize
    super
  end

  def configure(conf)
    super

    if @tag_format.nil? || @tag_format == DEFAULT_TAG_FORMAT
      @tag_format = DEFAULT_TAG_FORMAT
    else
      @tag_format = Regexp.new(conf['tag_format'])
    end
  end

  def start
    super
  end

  def format(tag, time, record)
    [tag, time, record].to_msgpack
  end

  def shutdown
    super
  end

  def write(chunk)
    solr_connection = {}

    chunk.msgpack_each do |tag, time, record|
      tag_parts = tag.match(@tag_format)
      id_key = tag_parts['primary_key']
      core_name = tag_parts['core_name'].nil? ? '' : tag_parts['core_name']
      url = "http://#{@host}:#{@port}/solr/#{core_name}"
      solr_connection[url] = RSolr.connect(:url => url) if solr_connection[url].nil?
      if tag_parts['event'] == 'delete'
        solr_connection[url].delete_by_id record[id_key]
      else
        message = Hash[record.map{ |k, v| [k.to_sym, v] }]
        message[:id] = record[id_key] if id_key && record[id_key]
        solr_connection[url].add message
      end
    end
    solr_connection.each {|solr| solr.commit }
  end
end
