# frozen_string_literal: true

module Zorki
  class Post
    def self.lookup(ids = [])
      # If a single id is passed in we make it the appropriate array
      ids = [ids] unless ids.kind_of?(Array)

      # Check that the ids are at least real ids
      # ids.each { |id| raise Birdsong::Error if !/\A\d+\z/.match(id) }

      self.scrape(ids)
    end

    attr_reader :id,
                :image_file_names,
                :text,
                :date,
                :number_of_likes,
                :user,
                :video_file_name,
                :video_preview_image,
                :screenshot_file

  private

    def initialize(post_hash = {})
      @id = post_hash[:id]
      @image_file_names = post_hash[:images]
      @text = post_hash[:text]
      @date = post_hash[:date]
      @number_of_likes = post_hash[:number_of_likes]
      @user = post_hash[:user]
      @video_file_name = post_hash[:video]
      @video_preview_image = post_hash[:video_preview_image]
      @screenshot_file = post_hash[:screenshot_file]
    end

    class << self
      private

        def scrape(ids)
          ids.map do |id|
            user_hash = Zorki::PostScraper.new.parse(id)
            Post.new(user_hash)
          end
        end
    end
  end
end
