require 'net/http'
require 'uri'
require 'yt/collections/base'
require 'yt/models/resumable_upload_session'

module Yt
  module Collections
    class ResumableUploadSessions < Base

      def insert(body = {}, options = {})
        @remote_url_auth = options[:remote_url_auth]
        content_length = resolve_file_size(options)

        @insert_options = options.merge(file_size: content_length)
        @headers = headers_for content_length

        @remote_auth = options[:remote_auth]
        do_insert body: body, headers: @headers
      end

      private

      def attributes_for_new_item(data)
        @insert_options.slice(:file_path, :remote_url, :file_size).tap do |attributes|
          attributes[:url] = data['Location']
          attributes[:content_type] = @parent.upload_content_type
          attributes[:chunk_size] = @insert_options.fetch(:chunk_size, 0)
          attributes[:max_retries] = @insert_options.fetch(:max_retries, 10)
          attributes[:auth] = @auth
          attributes[:remote_url_auth] = @remote_url_auth
          attributes[:remote_auth] = @remote_auth
        end
      end

      def insert_params
        super.tap do |params|
          params[:response_format] = nil
          params[:path] = @parent.upload_path
          # params[:method] = :post
          params[:params] = @parent.upload_params.merge uploadType: 'resumable'
        end
      end

      def resolve_file_size(options)
        if options[:file_path]
          File.size(options[:file_path])
        elsif options[:remote_url]
          uri = URI.parse(options[:remote_url])

          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
            request = Net::HTTP::Head.new(uri)
            request['Authorization'] = "Bearer #{remote_url_auth_token}"
            response = http.request(request)
            raise "Cannot determine remote file size: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
            response['Content-Length'].to_i
          end
        end
      end

      def headers_for(content_length)
        {}.tap do |headers|
          headers['X-Upload-Content-Length'] = content_length
          headers['X-Upload-Content-Type'] = @parent.upload_content_type
        end
      end

      # The result is not in the body but in the headers
      def extract_data_from(response)
        response.header
      end

      def remote_url_auth_token
        @remote_url_auth&.call || @auth.access_token
      end
    end
  end
end
