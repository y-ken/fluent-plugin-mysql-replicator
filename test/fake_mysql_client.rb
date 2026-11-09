require 'mysql2'

# A stand-in for Mysql2::Client in unit tests. Each query is recorded and answered by the given block, which returns
# the rows as an Array of Hashes. A closed client raises like a real one.
class FakeMysqlClient
  attr_reader :queries

  def initialize(&responder)
    @responder = responder
    @queries = []
    @closed = false
  end

  def query(sql)
    raise Mysql2::Error, 'MySQL client is not connected' if @closed
    @queries << sql
    (@responder.call(sql) || []).map(&:dup)
  end

  def ping
    !@closed
  end

  def close
    @closed = true
  end

  def closed?
    @closed
  end
end
