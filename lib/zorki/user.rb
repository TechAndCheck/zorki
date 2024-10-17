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

    def self.from_post_data(data)
      # "owner"=>
      #       {"id"=>"4303258197",
      #        "username"=>"petesouza",
      #        "is_verified"=>true,
      #        "profile_pic_url"=>
      #         "https://scontent-lax3-1.cdninstagram.com/v/t51.2885-19/433045134_436644512119229_523706897615373693_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lax3-1.cdninstagram.com&_nc_cat=1&_nc_ohc=N0A8l8Th9soQ7kNvgH0cKQQ&_nc_gid=29538825d3464a6f9b05bad4506fc1f9&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCIj0oEKb48mFW3Ag4tMW3nJitOdAe91hdIrIM_1nlwEw&oe=67163EE4&_nc_sid=d885a2",
      #        "blocked_by_viewer"=>false,
      #        "restricted_by_viewer"=>nil,
      #        "followed_by_viewer"=>false,
      #        "full_name"=>"Pete Souza",
      #        "has_blocked_viewer"=>false,
      #        "is_embeds_disabled"=>true,
      #        "is_private"=>false,
      #        "is_unpublished"=>false,
      #        "requested_by_viewer"=>false,
      #        "pass_tiering_recommendation"=>true,
      #        "edge_owner_to_timeline_media"=>{"count"=>3596},
      #        "edge_followed_by"=>{"count"=>3166659}},

      new_user_hash = {
        name: data["full_name"],
        username: data["username"],
        number_of_posts: data["edge_owner_to_timeline_media"]["count"],
        number_of_followers: data["edge_followed_by"]["count"],
        number_of_following: 0,
        verified: data["is_verified"],
        profile: "",
        profile_link: "https://www.instagram.com/#{data["username"]}",
        profile_image: Zorki.retrieve_media(data["profile_pic_url"]),
        profile_image_url: data["profile_pic_url"]
      }

      # Now we try and populate the profile
      begin
        scraped_user_hash = Zorki::UserScraper.new.parse(data["username"])
        new_user_hash[number_of_following: scraped_user_hash[:number_of_following]]
        new_user_hash[profile: scraped_user_hash[:profile]]
      rescue StandardError
        puts "#{new_user_hash[:name]}: User created, but cannot fill in the extra data"
        # If this didn't work we'll eat the error in the interest of completing successfully.
      end

      User.new(new_user_hash)
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
