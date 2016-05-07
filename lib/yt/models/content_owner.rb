require 'yt/models/account'

module Yt
  module Models
    # Provides methods to interact with YouTube CMS accounts.
    # @see https://cms.youtube.com
    # @see https://developers.google.com/youtube/analytics/v1/content_owner_reports
    class ContentOwner < Account

      # @!attribute [r] partnered_channels
      #   @return [Yt::Collections::PartneredChannels] the channels managed by the CMS account.
      has_many :partnered_channels

      # @!attribute [r] claims
      #   @return [Yt::Collections::Claims] the claims administered by the content owner.
      has_many :claims

      # @!attribute [r] assets
      #   @return [Yt::Collection::Assets] the assets administered by the content owner.
      has_many :assets

      # @!attribute [r] references
      #   @return [Yt::Collections::References] the references administered by the content owner.
      has_many :references

      # @!attribute [r] policies
      #   @return [Yt::Collections::Policies] the policies saved by the content owner.
      has_many :policies

      # @return [String] The display name of the content owner.
      attr_reader :display_name

      # @!attribute [r] video_groups
      #   @return [Yt::Collections::VideoGroups] the video-groups managed by the
      #     content owner.
      has_many :video_groups

      def initialize(options = {})
        super options
        @owner_name = options[:owner_name]
        @display_name = options[:display_name]
      end

      def create_reference(params = {})
        references.insert params
      end

      def create_asset(params = {})
        assets.insert params
      end

      def create_claim(params = {})
        claims.insert params
      end

    ### PRIVATE API ###

      # @private
      # Tells `has_many :videos` that account.videos should return all the
      # videos *on behalf of* the content owner (public, private, unlisted).
      def videos_params
        {for_content_owner: true, on_behalf_of_content_owner: @owner_name}
      end

      # @private
      # Tells `has_many :video_groups` that content_owner.video_groups should
      # return all the video-groups *on behalf of* the content owner
      def groups_params
        {on_behalf_of_content_owner: @owner_name}
      end
    end
  end
end
