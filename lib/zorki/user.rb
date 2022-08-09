# frozen_string_literal: true

module Zorki
  class User
    def self.lookup(usernames = [])
      # If a single id is passed in we make it the appropriate array
      usernames = [usernames] unless usernames.kind_of?(Array)

      # Check that the usernames are at least real usernames
      # usernames.each { |id| raise Birdsong::Error if !/\A\d+\z/.match(id) }

      self.scrape(usernames)
    end

    attr_reader :name,
                :username,
                :number_of_posts,
                :number_of_followers,
                :number_of_following,
                :verified,
                :profile,
                :profile_link,
                :profile_image,
                :profile_image_url

  private

    def initialize(user_hash = {})
      @name = user_hash[:name]
      @username = user_hash[:username]
      @number_of_posts = user_hash[:number_of_posts]
      @number_of_followers = user_hash[:number_of_followers]
      @number_of_following = user_hash[:number_of_following]
      @verified = user_hash[:verified]
      @profile = user_hash[:profile]
      @profile_link = user_hash[:profile_link]
      @profile_image = user_hash[:profile_image]
      @profile_image_url = user_hash[:profile_image_url]
    end

    class << self
      private

        def scrape(usernames)
          usernames.map do |username|
            user_hash = Zorki::UserScraper.new.parse(username)
            User.new(user_hash)
          end
        end
    end
  end
end
