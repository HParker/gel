require "pstore"

require_relative "httpool"
require_relative "tail_file"
require_relative "work_pool"

# For each URI, this stores:
#   * the local filename
#   * the current etag
#   * an external freshness token
#   * a stale flag
class Paperback::Pinboard
  UPDATE_CONCURRENCY = 8

  attr_reader :root
  def initialize(root, httpool: Paperback::Httpool.new)
    @root = root
    @httpool = httpool

    @pstore = PStore.new("#{root}/.pstore", true)
    @files = {}
    @waiting = Hash.new { |h, k| h[k] = [] }

    @update_pool = Paperback::WorkPool.new(UPDATE_CONCURRENCY, name: "paperback-pinboard")
  end

  def file(uri, token: nil, tail: true)
    unless @pstore.transaction(true) { @pstore[uri.to_s] }
      add uri, token: token
    end

    tail_file = Paperback::TailFile.new(uri, self, httpool: @httpool)
    tail_file.update(!tail) if stale(uri, token)

    if block_given?
      File.open(filename(uri), "r") do |f|
        yield f
      end
    end
  end

  def async_file(uri, token: nil, tail: true, only_updated: false)
    if stale(uri, token)
      unless @pstore.transaction(true) { @pstore[uri.to_s] }
        add uri, token: token
      end

      already_queued = @files.key?(uri)
      tail_file = @files[uri] ||= Paperback::TailFile.new(uri, self, httpool: @httpool)

      unless already_queued
        @update_pool.queue(uri.path) do
          tail_file.update(!tail)
        end
      end

      block = Proc.new
      @waiting[uri] << lambda do |f, changed|
        block.call(f) if changed || !only_updated
      end
    elsif block_given? && !only_updated
      File.open(filename(uri), "r") do |f|
        yield f
      end
    end
  end

  def add(uri, token: nil)
    filename = mangle_uri(uri)

    @pstore.transaction(false) do
      @pstore[uri.to_s] ||= {
        filename: filename,
        etag: nil,
        token: token,
        stale: true,
      }
    end
  end

  def filename(uri)
    File.expand_path(read(uri)[:filename], @root)
  end

  def etag(uri)
    read(uri)[:etag]
  end

  def stale(uri, token)
    @pstore.transaction(false) do
      h = @pstore[uri.to_s]
      return true unless h
      return h[:stale] if token && h[:token] == token || token == false
      h = h.merge(token: token, stale: true)
      @pstore[uri.to_s] = h
    end

    true
  end

  def read(uri)
    @pstore.transaction(true) do
      @pstore[uri.to_s]
    end
  end

  def updated(uri, etag, changed = true)
    @pstore.transaction(false) do
      @pstore[uri.to_s] = @pstore[uri.to_s].merge(etag: etag, stale: false)
    end

    return if @waiting[uri].empty?
    File.open(filename(uri), "r") do |f|
      @waiting[uri].each do |block|
        f.rewind
        block.call(f, changed)
      end
    end
  end

  private

  def mangle_uri(uri)
    "#{uri.hostname}--#{uri.path.gsub(/[^A-Za-z0-9]+/, "-")}--#{Digest(:SHA256).hexdigest(uri.to_s)[0, 12]}"
  end
end
