require 'yt/models/video'

module Yt
  module Models
    class GroupItem < Base
      attr_reader :auth, :data, :video, :channel

      def initialize(options = {})
        @data = options[:data]
        @auth = options[:auth]
        @video = options[:video] if options[:video]
        @channel = options[:channel] if options[:channel]
      end
    end
  end
end
