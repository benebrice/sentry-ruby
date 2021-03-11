require 'faraday'
require 'zlib'

module Sentry
  class HTTPTransport < Transport
    GZIP_ENCODING = "gzip"
    GZIP_THRESHOLD = 1024 * 30
    CONTENT_TYPE = 'application/x-sentry-envelope'
    RETRY_AFTER_HEADER = "retry-after"
    RATE_LIMIT_HEADER = "x-sentry-rate-limits"

    attr_reader :conn, :adapter, :rate_limits

    def initialize(*args)
      super
      @adapter = @transport_configuration.http_adapter || Faraday.default_adapter
      @conn = set_conn
      @endpoint = @dsn.envelope_endpoint
      @rate_limits = {}
    end

    def send_data(data)
      encoding = ""

      if should_compress?(data)
        data = Zlib.gzip(data)
        encoding = GZIP_ENCODING
      end

      conn.post @endpoint do |req|
        req.headers['Content-Type'] = CONTENT_TYPE
        req.headers['Content-Encoding'] = encoding
        req.headers['X-Sentry-Auth'] = generate_auth_header
        req.body = data
      end
    rescue Faraday::Error => e
      error_info = e.message

      if e.response
        if has_rate_limited_header?(e.response)
          handle_sentry_response(e.response)
        else
          error_info += "\nbody: #{e.response[:body]}"
          error_info += " Error in headers is: #{e.response[:headers]['x-sentry-error']}" if e.response[:headers]['x-sentry-error']
        end
      end

      raise Sentry::ExternalError, error_info
    end

    private

    def has_rate_limited_header?(response)
      response.dig(:headers, RETRY_AFTER_HEADER) || response.dig(:headers, RATE_LIMIT_HEADER)
    end

    def handle_sentry_response(response)
      if rate_limit_header = response.dig(:headers, RATE_LIMIT_HEADER)
        binding.pry

      end
    end

    def should_compress?(data)
      @transport_configuration.encoding == GZIP_ENCODING && data.bytesize >= GZIP_THRESHOLD
    end

    def set_conn
      server = @dsn.server

      configuration.logger.debug(LOGGER_PROGNAME) { "Sentry HTTP Transport connecting to #{server}" }

      Faraday.new(server, :ssl => ssl_configuration, :proxy => @transport_configuration.proxy) do |builder|
        @transport_configuration.faraday_builder&.call(builder)
        builder.response :raise_error
        builder.options.merge! faraday_opts
        builder.headers[:user_agent] = "sentry-ruby/#{Sentry::VERSION}"
        builder.adapter(*adapter)
      end
    end

    # TODO: deprecate and replace where possible w/Faraday Builder
    def faraday_opts
      [:timeout, :open_timeout].each_with_object({}) do |opt, memo|
        memo[opt] = @transport_configuration.public_send(opt) if @transport_configuration.public_send(opt)
      end
    end

    def ssl_configuration
      (@transport_configuration.ssl || {}).merge(
        :verify => @transport_configuration.ssl_verification,
        :ca_file => @transport_configuration.ssl_ca_file
      )
    end
  end
end
