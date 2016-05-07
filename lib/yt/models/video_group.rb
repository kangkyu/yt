require 'yt/models/base'

module Yt
  module Models
    # Provides methods to interact with YouTube Analytics video-groups.
    # @see https://developers.google.com/youtube/analytics/v1/reference/groups
    class VideoGroup < Base
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

    ### ANALYTICS ###

      # @macro reports

      # @macro report_by_video_dimensions
      has_report :views, Integer

      # @macro report_by_day
      has_report :uniques, Integer

      # @macro report_by_video_dimensions
      has_report :estimated_minutes_watched, Integer

      # @macro report_by_gender_and_age_group
      has_report :viewer_percentage, Float

      # @macro report_by_day_and_country
      has_report :comments, Integer

      # @macro report_by_day_and_country
      has_report :likes, Integer

      # @macro report_by_day_and_country
      has_report :dislikes, Integer

      # @macro report_by_day_and_country
      has_report :shares, Integer

      # @note This is not the total number of subscribers gained by the video’s
      #   channel, but the subscribers gained *from* the video’s page.
      # @macro report_by_day_and_country
      has_report :subscribers_gained, Integer

      # @note This is not the total number of subscribers lost by the video’s
      #   channel, but the subscribers lost *from* the video’s page.
      # @macro report_by_day_and_country
      has_report :subscribers_lost, Integer

      # @macro report_by_day_and_country
      has_report :favorites_added, Integer

      # @macro report_by_day_and_country
      has_report :favorites_removed, Integer

      # @macro report_by_day_and_country
      has_report :videos_added_to_playlists, Integer

      # @macro report_by_day_and_country
      has_report :videos_removed_from_playlists, Integer

      # @macro report_by_day_and_state
      has_report :average_view_duration, Integer

      # @macro report_by_day_and_state
      has_report :average_view_percentage, Float

      # @macro report_by_day_and_state
      has_report :annotation_clicks, Integer

      # @macro report_by_day_and_state
      has_report :annotation_click_through_rate, Float

      # @macro report_by_day_and_state
      has_report :annotation_close_rate, Float

      # @macro report_by_day_and_country
      has_report :earnings, Float

      # @macro report_by_day_and_country
      has_report :impressions, Integer

      # @macro report_by_day_and_country
      has_report :monetized_playbacks, Integer

      # @macro report_by_day_and_country
      has_report :playback_based_cpm, Float

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
