# frozen_string_literal: true

require "typhoeus"

module Zorki
  class UserScraper < Scraper
    def parse(username)
      # Stuff we need to get from the DOM (implemented is starred):
      # - *Name
      # - *Username
      # - *No. of posts
      # - *Verified
      # - *No. of followers
      # - *No. of people they follow
      # - *Profile
      #   - *description
      #   - *links
      # - *Profile image
      login

      graphql_script = get_content_of_subpage_from_url("https://instagram.com/#{username}/", "?username=")
      graphql_script = graphql_script.first if graphql_script.class == Array

      if graphql_script.nil?
        graphql_script = get_content_of_subpage_from_url("https://instagram.com/#{username}/", "web_profile_info")
      end

      if graphql_script.has_key?("author") && !graphql_script["author"].nil?
        user = graphql_script["author"]

        # Get the username (to verify we're on the right page here)
        scraped_username = user["identifier"]["value"]
        raise Zorki::Error unless username == scraped_username

        number_of_posts = graphql_script["interactionStatistic"].select do |stat|
          ["https://schema.org/FilmAction", "http://schema.org/WriteAction"].include?(stat["interactionType"])
        end.first

        number_of_followers = graphql_script["interactionStatistic"].select do |stat|
          stat["interactionType"] == "http://schema.org/FollowAction"
        end.first

        begin
          profile_image_url = user["image"]
          {
            name: user["name"],
            username: username,
            number_of_posts: Integer(number_of_posts["userInteractionCount"]),
            number_of_followers: Integer(number_of_followers["userInteractionCount"]),
            # number_of_following: user["edge_follow"]["count"],
            verified: user["is_verified"], # todo
            profile: graphql_script["description"],
            profile_link: user["sameAs"],
            profile_image: Zorki.retrieve_media(profile_image_url),
            profile_image_url: profile_image_url
          }
        end
      else
        user = graphql_script["data"]["user"]

        # Get the username (to verify we're on the right page here)
        scraped_username = user["username"]
        raise Zorki::Error unless username == scraped_username

        profile_image_url = user["profile_pic_url_hd"]
        {
          name: user["full_name"],
          username: username,
          number_of_posts: user["edge_owner_to_timeline_media"]["count"],
          number_of_followers: user["edge_followed_by"]["count"],
          number_of_following: user["edge_follow"]["count"],
          verified: user["is_verified"],
          profile: user["biography"],
          profile_link: user["external_url"],
          profile_image: Zorki.retrieve_media(profile_image_url),
          profile_image_url: profile_image_url
        }
      end
    end
  end
end
