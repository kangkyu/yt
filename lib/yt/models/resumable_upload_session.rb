# frozen_string_literal: true

require 'net/http' # for Net::HTTP.start
require 'uri' # for URI.parse
require 'json' # for JSON.parse
require 'yt/models/base'

module Yt
  module Models
    # @private
    # Provides methods to upload videos with the resumable upload protocol
    # using chunked PUTs with Content-Range headers.
    #
    # Unlike {ResumableSession} which sends the whole file in a single PUT,
    # this class uploads in 256 KB-aligned chunks and supports resuming
    # after interruptions.
    #
    # @see https://developers.google.com/youtube/v3/guides/using_resumable_upload_protocol
    #
    # @example
    #   session = account.resumable_upload_video('video.mp4',
    #     title: 'My Video',
    #     chunk_size: 10 * 1024 * 1024
    #   )
    #   loop do
    #     bytes_uploaded, video = session.next_chunk
    #     if video
    #       puts "Done! #{video.id}"
    #       break
    #     end
    #     puts "#{bytes_uploaded}/#{session.file_size} bytes"
    #   end
    class ResumableUploadSession < Base
      CHUNK_ALIGNMENT = 256 * 1024

      attr_reader :uri, :file_size, :bytes_uploaded

      def initialize(options = {})
        @uri          = options[:url] ? URI.parse(options[:url]) : nil
        @auth         = options[:auth]
        @file_path    = options[:file_path]
        @content_type = options.fetch(:content_type, 'video/*')
        @chunk_size   = align_chunk_size(options.fetch(:chunk_size, 0))
        @max_retries  = options.fetch(:max_retries, 10)

        if @file_path
          raise ArgumentError, "File not found: #{@file_path}" unless File.exist?(@file_path)
          raise ArgumentError, "File is empty: #{@file_path}"  if File.size(@file_path).zero?
          @file_size = File.size(@file_path)
        end

        @bytes_uploaded = 0
        @file_handle    = nil
        @complete       = false
      end

      # Uploads the next chunk of the file to the session URI.
      #
      # Returns a two-element array:
      # - +[bytes_uploaded, nil]+ when the upload is still in progress
      # - +[nil, Yt::Video]+     when the upload is complete
      #
      # @return [Array(Integer, nil), Array(nil, Yt::Video)]
      # @raise [Yt::Errors::RequestError] on permanent failure or expired session
      def next_chunk
        raise "No session URI — was initiation successful?" unless @uri
        raise "Upload already complete" if @complete

        ensure_file_open

        offset    = @bytes_uploaded
        chunk_end = [offset + effective_chunk_size - 1, @file_size - 1].min
        length    = chunk_end - offset + 1

        @file_handle.seek(offset)
        chunk_data = @file_handle.read(length)

        unless chunk_data && chunk_data.bytesize == length
          raise "Failed to read #{length} bytes at offset #{offset}"
        end

        content_range = "bytes #{offset}-#{chunk_end}/#{@file_size}"

        response = with_retries do
          http = Net::HTTP.new(@uri.host, @uri.port)
          http.use_ssl = true
          http.open_timeout = 30
          http.read_timeout = 300

          req = Net::HTTP::Put.new(@uri.request_uri)
          req['Authorization']  = "Bearer #{@auth.access_token}"
          req['Content-Length'] = length.to_s
          req['Content-Type']  = @content_type
          req['Content-Range'] = content_range
          req.body = chunk_data

          http.request(req)
        end

        handle_chunk_response(response, chunk_end)
      end

      # Queries the server for how many bytes have been received.
      # Useful after an interruption to find the resume point.
      #
      # @return [Integer] number of bytes the server has
      # @raise [Yt::Errors::RequestError] if session expired or request fails
      def check_status
        raise "No session URI" unless @uri

        response = with_retries do
          http = Net::HTTP.new(@uri.host, @uri.port)
          http.use_ssl = true

          req = Net::HTTP::Put.new(@uri.request_uri)
          req['Authorization']  = "Bearer #{@auth.access_token}"
          req['Content-Length'] = '0'
          req['Content-Range']  = "bytes */#{@file_size}"

          http.request(req)
        end

        case response.code.to_i
        when 200, 201
          @file_size
        when 308
          parse_range_header(response) || 0
        when 404
          raise Yt::Errors::RequestError, "Session URI expired (404)"
        else
          raise Yt::Errors::RequestError, "Status check failed: HTTP #{response.code}"
        end
      end

      # Uploads all remaining chunks and returns the completed video.
      #
      # @return [Yt::Video] the uploaded video
      def perform
        loop do
          bytes_uploaded, video = next_chunk
          return video if video
        end
        puts "#{bytes_uploaded}/#{session.file_size} bytes"
      end

      def complete?
        @complete
      end

      private

      def handle_chunk_response(response, chunk_end)
        code = response.code.to_i

        case code
        when 200, 201
          @complete = true
          @bytes_uploaded = @file_size
          close_file_handle

          data = JSON.parse(response.body)
          video = Yt::Video.new(
            id:      data['id'],
            snippet: data['snippet'],
            status:  data['status'],
            auth:    @auth,
          )
          [nil, video]
        when 308
          @bytes_uploaded = parse_range_header(response) || (chunk_end + 1)
          @uri = URI.parse(response['Location']) if response['Location']

          [@bytes_uploaded, nil]
        when 404
          close_file_handle
          raise Yt::Errors::RequestError, "Session URI expired (404). Start a new upload."
        else
          close_file_handle
          detail = begin
            parsed = JSON.parse(response.body)
            err = parsed.dig('error', 'errors', 0) || {}
            "#{err['reason']}: #{err['message']}"
          rescue
            response.body.to_s[0, 300]
          end
          raise Yt::Errors::RequestError, "Upload failed: HTTP #{code} — #{detail}"
        end
      end

      # "Range: bytes=0-999999" → 1000000
      def parse_range_header(response)
        range = response['Range']
        return nil unless range
        match = range.match(/bytes=(\d+)-(\d+)/)
        return nil unless match
        match[2].to_i + 1
      end

      def with_retries
        retries = 0
        loop do
          begin
            response = yield
            code = response.code.to_i
            return response unless retriable_http_codes.include?(code)

            retries += 1
            raise Yt::Errors::ServerError, "Max retries exceeded (HTTP #{code})" if retries > @max_retries

            wait = retry_delay(retries, response['Retry-After']&.to_i)
            sleep(wait)
          rescue *server_errors => e
            retries += 1
            raise Yt::Errors::ServerError, "Max retries exceeded: #{e.class}" if retries > @max_retries

            wait = retry_delay(retries)
            sleep(wait)
          end
        end
      end

      def retry_delay(attempt, server_retry_after = nil)
        return server_retry_after if server_retry_after && server_retry_after > 0
        max_delay = [64.0, 1.0 * (2**attempt)].min
        rand * max_delay
      end

      def ensure_file_open
        @file_handle ||= File.open(@file_path, 'rb')
      end

      def close_file_handle
        @file_handle&.close
        @file_handle = nil
      end

      def effective_chunk_size
        chunked? ? @chunk_size : @file_size
      end

      def chunked?
        @chunk_size > 0
      end

      def align_chunk_size(size)
        return 0 if size.nil? || size <= 0
        aligned = ((size + CHUNK_ALIGNMENT - 1) / CHUNK_ALIGNMENT) * CHUNK_ALIGNMENT
        [aligned, CHUNK_ALIGNMENT].max
      end

      def retriable_http_codes
        [500, 502, 503, 504]
      end

      def server_errors
        [
          OpenSSL::SSL::SSLError,
          Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT,
          Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EPIPE,
          Net::OpenTimeout, Net::ReadTimeout, IOError, SocketError,
        ]
      end
    end
  end
end
