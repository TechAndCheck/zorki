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

# {"@context"=>"https://schema.org",
#  "@type"=>"ProfilePage",
#  "description"=>"founder",
#  "author"=>
#   {"@type"=>"Person",
#    "identifier"=>{"@type"=>"http://schema.org/PropertyValue", "propertyID"=>"Username", "value"=>"therock"},
#    "image"=>
#     "https://scontent-lga3-2.cdninstagram.com/v/t51.2885-19/11850309_1674349799447611_206178162_a.jpg?stp=dst-jpg_s100x100&_nc_cat=1&ccb=1-7&_nc_sid=8ae9d6&_nc_ohc=Fu_smFNQ2A0AX-6pazq&_nc_ht=scontent-lga3-2.cdninstagram.com&oh=00_AfCvLCw6Xpt-lB4iZs-N1RilNF2BDuiT5nGcBOjZW-naaw&oe=648B85C4",
#    "name"=>"Dwayne Johnson",
#    "alternateName"=>"@therock",
#    "sameAs"=>"https://linktr.ee/therock",
#    "url"=>"https://www.instagram.com/therock"},
#  "mainEntityOfPage"=>{"@type"=>"ProfilePage", "@id"=>"https://www.instagram.com/therock/"},
#  "identifier"=>{"@type"=>"http://schema.org/PropertyValue", "propertyID"=>"Username", "value"=>"therock"},
#  "interactionStatistic"=>
#   [{"@type"=>"InteractionCounter", "interactionType"=>"https://schema.org/FilmAction", "userInteractionCount"=>"7271"},
#    {"@type"=>"InteractionCounter", "interactionType"=>"http://schema.org/FollowAction", "userInteractionCount"=>"406332272"}]}
      if graphql_script.has_key?("author") && !graphql_script["author"].nil?
        user = graphql_script["author"]

        # Get the username (to verify we're on the right page here)
        scraped_username = user["identifier"]["value"]
        raise Zorki::Error unless username == scraped_username

        number_of_posts = graphql_script["interactionStatistic"].select do |stat|
          stat["interactionType"] == "https://schema.org/FilmAction"
        end.first

        number_of_followers = graphql_script["interactionStatistic"].select do |stat|
          stat["interactionType"] == "http://schema.org/FollowAction"
        end.first

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
