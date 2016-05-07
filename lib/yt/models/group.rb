require 'yt/models/base'

module Yt
  module Models
    # @see https://developers.google.com/youtube/analytics/v1/reference/groups
    # four item types `youtube#channel`, `youtube#playlist`, `youtube#video`, `youtubePartner#asset`
    class Group < Base
      # @private
      attr_reader :id, :auth

    ### GROUP INFO ###

      has_one :group_info

      # @!attribute [r] title
      #   @return [String] the title of the group.
      delegate :title, to: :group_info

      # @!attribute [r] item_count
      #   @return [Integer] the number of resources in the group.
      delegate :item_count, to: :group_info

      # @!attribute [r] published_at
      #   @return [Time] the date and time when the group was created.
      delegate :published_at, to: :group_info

      # @!attribute [r] item_type
      #   @return [String] the type of of the group.
      delegate :item_type, to: :group_info

    ### ASSOCIATIONS ###

      # @!attribute [r] group_items
      #   @return [Yt::Collections::GroupItems] the group’s items.
      has_many :group_items

    ### PRIVATE API ###

      # @private
      def initialize(options = {})
        @id = options[:id]
        @auth = options[:auth]
        @group_info = options[:group_info] if options[:group_info]
      end

      # @private
      # Tells `has_reports` to retrieve group reports from the Analytics API.
      def reports_params
        {}.tap do |params|
          if auth.owner_name
            params[:ids] = "contentOwner==#{auth.owner_name}"
          else
            params[:ids] = "channel==mine"
          end
          params[:filters] = "group==#{id}"
        end
      end
    end
  end
end
