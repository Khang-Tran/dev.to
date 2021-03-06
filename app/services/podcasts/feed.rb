require "rss"
require "rss/itunes"

module Podcasts
  class Feed
    def initialize(podcast)
      @podcast = podcast
    end

    def get_episodes(limit: 100, force_update: false)
      rss = HTTParty.get(podcast.feed_url).body
      feed = RSS::Parser.parse(rss, false)

      set_unreachable(:unparsable, force_update) && return unless feed

      get_episode = Podcasts::GetEpisode.new(podcast)
      feed.items.first(limit).each do |item|
        get_episode.call(item: item, force_update: force_update)
      end
      podcast.update_columns(reachable: true, status_notice: "")
      feed.items.size
    rescue Net::OpenTimeout, Errno::ECONNREFUSED, SocketError => _e
      set_unreachable(:unreachable, force_update)
    rescue OpenSSL::SSL::SSLError => _e
      set_unreachable(:ssl_failed, force_update)
    rescue RSS::NotWellFormedError => _e
      set_unreachable(:unparsable, force_update)
    end

    private

    attr_reader :podcast

    def set_unreachable(status = :unreachable, force_update = false)
      # don't recheck if the podcast was already unreachable or force update is required
      need_refetching = podcast.reachable || force_update
      podcast.update_columns(reachable: false, status_notice: I18n.t(status, scope: "podcasts.statuses"))
      refetch_items if need_refetching
      true
    end

    # When setting podcast feed as unreachable, we need to re-check the episodes URLs.
    # If the episodes URLs are still reachable, the podcast will remain on the site.
    # If they are not, the podcast will be hidden.
    def refetch_items
      podcast.podcast_episodes.find_each do |episode|
        PodcastEpisodes::UpdateMediaUrlJob.perform_later(episode.id, episode.media_url)
      end
    end
  end
end
