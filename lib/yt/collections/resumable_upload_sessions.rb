require 'net/http'
require 'uri'
require 'yt/collections/base'
require 'yt/models/resumable_upload_session'

module Yt
  module Collections
    class ResumableUploadSessions < Base

      def insert(body = {}, options = {})
        content_length = resolve_file_size(options)
        @insert_options = options.merge(file_size: content_length)
        @headers = headers_for content_length
        do_insert body: body, headers: @headers
      end

      private

      def attributes_for_new_item(data)
        {
          url: data['Location'],
          auth: @auth,
          content_type: @parent.upload_content_type,
          file_path: @insert_options[:file_path],
          remote_url: @insert_options[:remote_url],
          remote_auth: @insert_options[:remote_auth],
          file_size: @insert_options[:file_size],
          chunk_size: @insert_options.fetch(:chunk_size, 0),
          max_retries: @insert_options.fetch(:max_retries, 10)
        }
      end

      def insert_params
        super.tap do |params|
          params[:response_format] = nil
          params[:path] = @parent.upload_path
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
            request['Authorization'] = options[:remote_auth].call
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
    end
  end
end
