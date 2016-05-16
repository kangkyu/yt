require 'yt/collections/base'
require 'yt/models/group_item'

module Yt
  module Collections
    # @private
    class GroupItems < Base

    private

      def attributes_for_new_item(data)
        super(data).tap do |attributes|
          attributes[:video] = data['video']
        end
      end

      def list_params
        super.tap do |params|
          params[:path] = "/youtube/analytics/v1/groupItems"
          params[:params] = {group_id: @parent.id}
          if @auth.owner_name
            params[:params][:on_behalf_of_content_owner] = @auth.owner_name
          end
        end
      end

      def eager_load_items_from(items)
        if included_relationships.include?(:video)
          case @parent.group_info.data['itemType']
          when "youtube#video"
            all_video_ids = items.map{|item| item['resource']['id']}.uniq
            load_videos_from_video_ids(all_video_ids) do |videos|
              items.each do |item|
                video = videos.find{|v| v.id == item['resource']['id']}
                item['video'] = video if video
              end
            end
          when "youtube#channel"
            all_channel_ids = items.map{|item| item['resource']['id']}.uniq
            load_videos_from_channel_ids(all_channel_ids) do |videos|
              items.each do |item|
                video = item.videos.find{|v| v.id == item['resource']['id']}
                item['video'] = video if video
              end
            end
          end
        end
        super
      end

      def load_videos_from_video_ids(video_ids)
        video_ids.each_slice(50) do |video_ids|
          conditions = {id: video_ids.join(',')}
          conditions[:part] = 'snippet,status,statistics,contentDetails'
          videos = Collections::Videos.new(auth: @auth).where conditions
          yield videos
        end
      end

      def load_videos_from_channel_ids(channel_ids)
        channel_ids.each do |channel_id|
          channel = Yt::Channel.new(id: channel_id, auth: @auth)
          # conditions = {channel_id: channel_id}
          # conditions[:part] = 'snippet,status,statistics,contentDetails'
          # videos = Collections::Videos.new(auth: @auth).where conditions
          yield channel.videos
        end
      end
    end
  end
end
