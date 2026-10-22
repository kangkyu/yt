# encoding: UTF-8
require 'spec_helper'
require 'yt/models/channel'

describe Yt::Collections::Reports, :partner, :vcr do
  let(:channel) { Yt::Channel.new id: ENV['YT_TEST_PARTNER_CHANNEL_ID'], auth: test_content_owner }
  let(:range) { {since: 1.year.ago.to_date, until: 3.days.ago.to_date} }
  let(:metrics) { [:views, :estimated_minutes_watched] }

  describe 'reports by video of given videos, more than one page of them' do
    let(:video_ids) { channel.videos.first(120).map(&:id) }
    let(:reports) { channel.reports range.merge(only: metrics, by: :video, videos: video_ids) }
    let(:reports_by_page) do
      video_ids.each_slice(50).map do |ids|
        channel.reports range.merge(only: metrics, by: :video, videos: ids)
      end.reduce(:deep_merge)
    end

    it 'have every video, going on from page to page with startIndex' do
      expect(reports[:views].size).to be > 50
      expect(reports).to eq reports_by_page
    end
  end

  describe 'reports by video without given videos' do
    let(:reports) { channel.reports range.merge(only: metrics, by: :video) }

    it 'have the top 50 videos only' do
      expect(reports[:views].size).to be_between(1, 50)
    end
  end
end
