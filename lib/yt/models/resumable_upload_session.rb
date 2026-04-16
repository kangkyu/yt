# frozen_string_literal: true

require 'net/http' # for Net::HTTP.start
require 'uri' # for URI.parse
require 'json' # for JSON.parse
require 'yt/models/base'
require 'yt/actions/upload'

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
    #
    #   or (on Rails 8)
    #
    #   session = account.resumable_upload_video(
    #     drive_url,
    #     remote_auth: -> { account.access_token },
    #     remote_url_auth: -> { user.access_token },
    #     title: 'My Video',
    #     privacy_status: 'private',
    #     self_declared_made_for_kids: false,
    #     chunk_size: 10 * 1024 * 1024
    #   )
    #   video = session.perform do |bytes_uploaded, file_size|
    #     percent = (bytes_uploaded * 100.0 / file_size).round
    #     upload.broadcast_replace_to(
    #       [user, "uploads"],
    #       target: "upload_progress_#{upload.id}",
    #       partial: "uploads/progress",
    #       locals: { upload: upload, percent: percent }
    #     )
    #   end
    class ResumableUploadSession < Base
      include Actions::Upload
      CHUNK_ALIGNMENT = 256 * 1024

      attr_reader :uri, :file_size, :bytes_uploaded

      def initialize(options = {})
        @uri            = options[:url] ? URI.parse(options[:url]) : nil
        @auth           = options[:auth]
        @file_path      = options[:file_path]
        @remote_url     = options[:remote_url]
        @remote_url_auth = options[:remote_url_auth]
        @remote_auth = options[:remote_auth]
        @content_type   = options.fetch(:content_type, 'video/*')
        @chunk_size     = align_chunk_size(options.fetch(:chunk_size, 0))
        @max_retries    = options.fetch(:max_retries, 10)

        @file_size = options[:file_size]

        @bytes_uploaded   = 0
        @file_handle      = nil
        @remote_http      = nil
        @upload_http      = nil
        @complete         = false
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

        offset    = @bytes_uploaded
        chunk_end = [offset + effective_chunk_size - 1, @file_size - 1].min
        length    = chunk_end - offset + 1

        chunk_data = if @remote_url
          read_remote_chunk(offset, chunk_end)
        else
          ensure_file_open
          @file_handle.seek(offset)
          @file_handle.read(length)
        end

        unless chunk_data && chunk_data.bytesize == length
          raise "Failed to read #{length} bytes at offset #{offset}"
        end

        response = with_retries do
          do_upload headers: upload_headers(length, offset, chunk_end), body: chunk_data
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
          do_upload headers: upload_headers(0)
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
          yield bytes_uploaded, @file_size if block_given?
        end
      end

      def complete?
        @complete
      end

      private

      def upload_params
        { uri: @uri, token: remote_auth_token, http: ensure_upload_http }
      end

      def upload_headers(length, offset = nil, chunk_end = nil)
        {
          'Content-Length' => length.to_s,
          'Content-Range'  => offset ? "bytes #{offset}-#{chunk_end}/#{@file_size}" : "bytes */#{@file_size}",
        }.tap do |headers|
          headers['Content-Type'] = @content_type if offset
        end
      end

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

      def read_remote_chunk(offset, chunk_end)
        uri = URI.parse(@remote_url)
        request = Net::HTTP::Get.new(uri)
        token = remote_url_auth_token
        request['Authorization'] = "Bearer #{token}" if token.present?
        request['Range'] = "bytes=#{offset}-#{chunk_end}"
        response = ensure_remote_http.request(request)
        unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPPartialContent)
          raise "Remote read failed: HTTP #{response.code}"
        end
        response.body
      end

      def ensure_file_open
        @file_handle ||= File.open(@file_path, 'rb')
      end

      def ensure_remote_http
        if @remote_http.nil? || !@remote_http.started?
          uri = URI.parse(@remote_url)
          @remote_http = Net::HTTP.new(uri.host, uri.port)
          @remote_http.use_ssl = uri.scheme == 'https'
          @remote_http.open_timeout = 30
          @remote_http.read_timeout = 300
          @remote_http.keep_alive_timeout = 120
          @remote_http.start
        end
        @remote_http
      end

      def ensure_upload_http
        if @upload_http.nil? || !@upload_http.started?
          @upload_http = Net::HTTP.new(@uri.host, @uri.port)
          @upload_http.use_ssl = true
          @upload_http.open_timeout = 30
          @upload_http.read_timeout = 300
          @upload_http.keep_alive_timeout = 120
          @upload_http.start
        end
        @upload_http
      end

      def close_file_handle
        @file_handle&.close
        @file_handle = nil
        @remote_http&.finish if @remote_http&.started?
        @remote_http = nil
        @upload_http&.finish if @upload_http&.started?
        @upload_http = nil
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

      def remote_auth_token
        @remote_auth&.call || @auth.access_token
      end

      def remote_url_auth_token
        return @remote_url_auth.call if @remote_url_auth
        @remote_auth&.call || @auth.access_token
      end
    end
  end
end
