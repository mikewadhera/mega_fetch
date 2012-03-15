
require 'fiber'
require 'net/http'
require 'yajl'
require 'timeout'

module MegaFetch

  class << self
    attr_accessor :access_token
  end

  class LazyEnumerable
    include Enumerable

    attr_reader :offset

    def initialize(enumerable)
      @offset     = 0
      @enumerable = enumerable
      @generator  = Fiber.new { @enumerable.each { |o| @offset += 1; Fiber.yield(o) } }
    end

    def each(&block)
      while @generator.alive?
        block.call(@generator.resume)
      end
    end

    def inspect
      @enumerable.inspect
    end

  end

  class Stream
    include Enumerable

    def initialize(enumerable, options = {})
      @lazy    = LazyEnumerable.new(enumerable)
      @edge    = options[:edge]     || "/"
      @client  = options[:client]   || client_factory()
      @failed  = {}
    end

    def each(&block)
      last_request = @lazy.reduce(request_factory()) do |request, node|
        if node
          node = node.to_s.strip

          begin
            request << node
          rescue BatchedRequest::Full
            flush(request, &block)

            new_empty_request = request_factory()
            new_empty_request << node
          end
        else
          request
        end
      end
      
      # We're done reducing the nodes over batched requests
      # However, our last request may have nodes left so flush one last time if needed
      flush(last_request, &block) if last_request.any?
      
      self
    end

    def request_factory
      BatchedRequest.new(@edge, calculate_batched_request_size())
    end

    def client_factory
      Client.new(calculate_client_timeout())
    end

    def inspect
      state = { offset: @lazy.offset, client: @client, failed: @failed.size }
      %(#<#{self.class}: #{@lazy.inspect}, #{state.map { |k,v| k.to_s + ': ' + v.inspect}.join(', ')}>)
    end

    protected

    def flush(request, &block)
      begin
        http_response = @client.post("/batch", :batch => request.to_json)
        response      = BatchedResponse.new(request, http_response.body)
        response.parse!
        response.nodes.each(&block)
      end
    end

    def calculate_client_timeout
      case @edge
      when "/posts" then 60
      else
        Client::Config[:default_timeout]
      end
    end

    def calculate_batched_request_size
      case @edge
      when "/posts" then 5
      else
        BatchedRequest::MaximumBatches
      end
    end

  end

  class BatchedResponse
    class ParseError < StandardError; end
    class BadRequest < StandardError; end

    ParseOpts = { :symbolize_keys => true }

    attr_reader :nodes

    def initialize(request, body)
      @request = request
      @body    = body
      @nodes   = []
    end

    def parse!
      json = Yajl::Parser.parse(@body, ParseOpts)
      json.each do |batch|
        code, headers, body = batch.values_at(:code, :headers, :body)
        nodes = Yajl::Parser.parse(body, ParseOpts)
        unless nodes[:error]
          nodes.each do |id, node|
            @nodes << [id, node]
          end
        end
      end
    rescue Yajl::ParseError => e
      raise Response::ParseError, "Bad Batch: (#{e.inspect}) #{@body.inspect}"  
    end

  end

  class BatchedRequest
    class Full < StandardError; end

    MaximumBatches = 20

    attr_reader :edge

    def initialize(edge, capacity)
      @batches  = [batch_factory()]
      @edge     = edge
      @capacity = capacity
    end

    def <<(node)
      begin
        @batches.last << node
      rescue Batch::Full
        raise Full if @batches.size == @capacity
        @batches << batch_factory()
        retry
      end
      self
    end

    def batch_factory
      Batch.new(Batch::MaximumNodes)
    end

    def size
      @batches.size
    end

    def any?
      @batches.any? { |batch| batch.any? }
    end

    def nodes
      @batches.flat_map { |batch| batch.nodes }
    end

    def to_json
      Yajl::Encoder.encode(@batches.map { |batch|
        {
          method:       "GET",
          relative_url: "#{@edge}?ids=#{batch.nodes.join(',')}"
        }
      })
    end

  end

  class Batch
    class Full < StandardError; end

    MaximumNodes = 20

    attr_reader :nodes

    def initialize(capacity)
      @nodes    = []
      @capacity = capacity
    end

    def <<(node)
      raise Full if @nodes.size == @capacity
      @nodes << node
      self
    end

    def size
      @nodes.size
    end

    def any?
      @nodes.any?
    end
  end

  class Client
    class ServerError < StandardError; end
    class UnexpectedRedirect < StandardError; end

    Config = {
      default_timeout: 10,
      retry: {
        on:            [ServerError, Timeout::Error, Errno::EPIPE, Errno::ETIMEDOUT, Errno::EINVAL, Errno::ECONNRESET, EOFError, SocketError],
        max:           4,
        delay_seconds: lambda { |tries| (tries - 1) * 2 }
      }
    }

    def initialize(timeout_seconds)
      @graph              = Net::HTTP.new("graph.facebook.com", 443)
      @graph.use_ssl      = true
      @requests_attempted = 0
      @requests_completed = 0
      @requests_timedout  = 0
      @server_errors      = 0
      @timeout_seconds    = timeout_seconds
    end

    def post(path, params={})
      post           = Net::HTTP::Post.new(path)
      access_token   = MegaFetch.access_token
      post.form_data = params.merge(:access_token => access_token.respond_to?(:call) ? access_token.call : access_token.dup)

      http do
        @graph.start { @graph.request(post) }
      end
    end

    def inspect
      state = { 
                timeout_seconds:    @timeout_seconds,
                requests_attempted: @requests_attempted,
                requests_completed: @requests_completed,
                requests_timedout:  @requests_timedout,
                server_errors:      @server_errors
              }
      %(#<#{self.class}: #{@graph.inspect}, #{state.map { |k,v| k.to_s + ': ' + v.inspect}.join(', ')}>)
    end

    protected

    def http(&block)
      tries = 0

      #puts "Attempting HTTP..."
      begin
        @requests_attempted += 1

        result = block.call#Timeout::timeout(@timeout_seconds, &block)

        @requests_completed += 1

        raise ServerError if result.code =~ /5../
        raise UnexpectedRedirect if result.code =~ /3../

        return result
      rescue *Config[:retry][:on] => retryable
        puts "Retrying..."
        tries += 1

        case retryable
        when Timeout::Error
          @requests_timedout += 1
        when ServerError
          @server_errors += 1
        end

        raise if tries > Config[:retry][:max]
        delay = Config[:retry][:delay_seconds].call(tries)
        sleep(delay)
        retry
      end
    end
  end
end