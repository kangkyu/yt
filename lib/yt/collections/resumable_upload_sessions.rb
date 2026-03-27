require 'yt/collections/base'
require 'yt/models/resumable_upload_session'

module Yt
  module Collections
    class ResumableUploadSessions < Base

      def insert(content_length, body = {}, options = {})
        @headers = headers_for content_length
        @insert_options = options
        do_insert body: body, headers: @headers
      end

      private

      def attributes_for_new_item(data)
        {
          url: data['Location'],
          auth: @auth,
          content_type: @parent.upload_content_type,
          file_path: @insert_options[:file_path],
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
