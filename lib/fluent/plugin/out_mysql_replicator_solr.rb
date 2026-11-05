require 'rsolr'
require 'erb'
require 'fluent/plugin/output'

class Fluent::Plugin::MysqlReplicatorSolrOutput < Fluent::Plugin::Output
  Fluent::Plugin.register_output('mysql_replicator_solr', self)

  DEFAULT_BUFFER_TYPE = "memory"

  helpers :compat_parameters

  config_param :host, :string,  :default => 'localhost'
  config_param :port, :integer, :default => 8983
  config_param :tag_format, :string, :default => nil

  config_section :buffer do
    config_set_default :@type, DEFAULT_BUFFER_TYPE
  end

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

  def multi_workers_ready?
    true
  end

  def formatted_to_msgpack_binary?
    true
  end

  def write(chunk)
    # A record whose tag does not match tag_format cannot be written. The whole chunk, with its other records, is not
    # sent, and Fluent::UnrecoverableError makes Fluentd move it to the backup directory (or to <secondary>) at once,
    # instead of retrying it. The message gives the tags and the number of records, not their contents.
    unmatched_tags = Hash.new(0)
    chunk.msgpack_each {|tag, _time, _record| unmatched_tags[tag] += 1 unless tag.match?(@tag_format) }
    unless unmatched_tags.empty?
      count = unmatched_tags.values.sum
      tags = unmatched_tags.first(10).map {|tag, n| "#{tag} (#{n})" }.join(', ')
      raise Fluent::UnrecoverableError, "mysql_replicator_solr: #{count} records in the chunk have a tag that does not match tag_format #{@tag_format.inspect}, so the chunk is not written: #{tags}"
    end

    solr_connection = {}

    chunk.msgpack_each do |tag, time, record|
      tag_parts = tag.match(@tag_format)
      id_key = tag_parts['primary_key']
      core_name = tag_parts['core_name'].nil? ? '' : tag_parts['core_name']
      # URI.escape was removed in Ruby 3.0. The core name is one segment of the path.
      url = "http://#{@host}:#{@port}/solr/#{ERB::Util.url_encode(core_name)}"
      solr_connection[url] = RSolr.connect(:url => url) if solr_connection[url].nil?
      if tag_parts['event'] == 'delete'
        solr_connection[url].delete_by_id record[id_key]
      else
        message = Hash[record.map{ |k, v| [k.to_sym, v] }]
        message[:id] = record[id_key] if id_key && record[id_key]
        solr_connection[url].add message
      end
    end
    solr_connection.each_value(&:commit)
  end
end
