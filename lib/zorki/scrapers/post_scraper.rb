# frozen_string_literal: true

require "typhoeus"

# rubocop:disable Metrics/ClassLength
module Zorki
  class PostScraper < Scraper
    def parse(id)
      count = 0

      until count == 2
        puts "Retrieving ID #{id}"

        begin
          result = attempt_parse(id)
          break
        rescue ImageRequestZeroSize
          # If the image is zero size, we retry
          puts "Zero sized image found, retrying #{count}"
          count += 1
        end
      end

      raise ImageRequestZeroSize if count == 5

      result
    ensure
      page.quit
      # Make sure it's quit? I'm not sure we really want to do this outside of testing.
    end

    def attempt_parse(id)
      # Stuff we need to get from the DOM (implemented is starred):
      # - User *
      # - Text *
      # - Image * / Images * / Video *
      # - Date *
      # - Number of likes *
      # - Hashtags

      Capybara.app_host = "https://instagram.com"

      # video slideshows https://www.instagram.com/p/CY7KxwYOFBS/?utm_source=ig_embed&utm_campaign=loading
      #
      # TODO: Check if post is available publically before trying to login
      # Should help with the scraping
      # login
      # graphql_object = get_content_of_subpage_from_url(
      #   "https://www.instagram.com/p/#{id}/",
      #   "/graphql/query",
      #   "data,xdt_shortcode_media,edge_sidecar_to_children",
      #   post_data_include: "PolarisPostRootQuery"
      # )

      graphql_object = get_content_of_subpage_from_url(
              "https://www.instagram.com/p/#{id}/",
              "/graphql/query",
              nil,
              post_data_include: "shortcode"
            )

      graphql_object = graphql_object.first if graphql_object.kind_of?(Array)

      # For pages that have been marked misinfo the structure is very different than not
      # If it is a clean post then it's just a schema.org thing, but if it's misinfo it's the old
      # way of deeply nested stuff.
      #
      # First we check which one we're getting

      if graphql_object.has_key?("articleBody")
        # Let's just parse the images first
        images = graphql_object["image"].map do |image|
          Zorki.retrieve_media(image["url"])
        end

        text = graphql_object["articleBody"]
        username = graphql_object["author"]["identifier"]["value"]
        # 2021-04-01T17:07:10-07:00

        date = DateTime.strptime(graphql_object["dateCreated"], "%Y-%m-%dT%H:%M:%S%z")
        interactions = graphql_object["interactionStatistic"]
        number_of_likes = interactions.select do |x|
          x["interactionType"] == "http://schema.org/LikeAction"
        end.first["userInteractionCount"]

        unless graphql_object["video"].empty?
          video_url = graphql_object["video"].first["contentUrl"]
          video = Zorki.retrieve_media(video_url)

          video_preview_image_url = graphql_object["video"].first["thumbnailUrl"]
          video_preview_image = Zorki.retrieve_media(video_preview_image_url)
        end
      elsif graphql_object.has_key?("items") || !graphql_object.dig("data", "xdt_api__v1__media__shortcode__web_info", "items").nil?
        # We need to see if this is a single image post or a slideshow. We do that
        # by looking for a single image, if it's not there, we assume the alternative.
        # debugger
        unless graphql_object.has_key?("items")
          graphql_object = graphql_object["data"]["xdt_api__v1__media__shortcode__web_info"]
        end

        unless graphql_object["items"][0].has_key?("video_versions") && !graphql_object["items"][0]["video_versions"].nil?
          # Check if there is a slideshow or not
          unless graphql_object["items"][0].has_key?("carousel_media") && !graphql_object["items"][0]["carousel_media"].nil?
            # Single image
            image_url = graphql_object["items"][0]["image_versions2"]["candidates"][0]["url"]
            images = [Zorki.retrieve_media(image_url)]
          else
            # Slideshow
            images = graphql_object["items"][0]["carousel_media"].map do |media|
              Zorki.retrieve_media(media["image_versions2"]["candidates"][0]["url"])
            end
          end
        else
          # some of these I've seen in both ways, thus the commented out lines
          # video_url = graphql_object["entry_data"]["PostPage"].first["graphql"]["shortcode_media"]["video_url"]
          video_url = graphql_object["items"][0]["video_versions"][0]["url"]
          video = Zorki.retrieve_media(video_url)
          # video_preview_image_url = graphql_object["entry_data"]["PostPage"].first["graphql"]["shortcode_media"]["display_resources"].last["src"]
          video_preview_image_url = graphql_object["items"][0]["image_versions2"]["candidates"][0]["url"]
          video_preview_image = Zorki.retrieve_media(video_preview_image_url)
        end

        unless graphql_object["items"][0]["caption"].nil?
          text = graphql_object["items"][0]["caption"]["text"]
        else
          text = ""
        end

        username = graphql_object["items"][0]["user"]["username"]

        date = DateTime.strptime(graphql_object["items"][0]["taken_at"].to_s, "%s")
        number_of_likes = graphql_object["items"][0]["like_count"]
      elsif graphql_object.has_key?("data")
        # TODO This is the new way of doing things, we need to figure it out
        # Go through the entire JSON structure (below for now) and make sure it hits all the points

        object = graphql_object["data"]["xdt_shortcode_media"]

        begin
          date = object["edge_media_to_caption"]["edges"].first["node"]["created_at"]
        rescue StandardError
          date = object["taken_at_timestamp"].to_s
        end

        date = DateTime.strptime(date, "%s")

        begin
          text = object["edge_media_to_caption"]["edges"].first["node"]["text"]
        rescue StandardError
          text = ""
        end

        number_of_likes = object["edge_media_preview_like"]["count"]
        username = object["owner"]["username"]
        id = object["shortcode"]

        images = []
        video = nil
        video_preview_image = nil

        if object.has_key?("edge_sidecar_to_children")
          object["edge_sidecar_to_children"]["edges"].each do |edge|
            media = Zorki.retrieve_media(edge["node"]["display_resources"].last["src"])
            images << media if edge["node"]["is_video"] == false

            if edge["node"]["is_video"] == true
              video = media
              video_preview_image = Zorki.retrieve_media(edge["node"]["display_resources"]["display_url"])
              break # We only support one video right now, we'll fix later
            end
          end
        elsif object.has_key?("display_resources")
          if object["is_video"] == true
            video = Zorki.retrieve_media(object["video_url"])
            video_preview_image = Zorki.retrieve_media(object["display_url"])
          else
            images << Zorki.retrieve_media(object["display_resources"].last["src"])
          end
        end

        user = User.from_post_data(object["owner"])
      end

      screenshot_file = take_screenshot()

      # This has to run last since it switches pages
      user = User.lookup([username]).first if defined?(user).nil?

      {
        images: images,
        video: video,
        video_preview_image: video_preview_image,
        screenshot_file: screenshot_file,
        text: text,
        date: date,
        number_of_likes: number_of_likes,
        user: user,
        id: id
      }
    end

    def take_screenshot
      # First check if a post has a fact check overlay, if so, clear it.
      # The only issue is that this can take *awhile* to search. Not sure what to do about that
      # since it's Instagram's fault for having such a fucked up obfuscated hierarchy
      #
      # Disabling this because it doesn't work right now when we're not logging in
      # Eventually we want to especially get the login modal closed
      # begin
      #   find_button("Close").click
      #   sleep(1)
      #   find_button("See Post").click
      #   sleep(0.1)
      # rescue Capybara::ElementNotFound
      #   # Do nothing if the element is not found
      # end

      # Take the screenshot and return it
      # rubocop:disable Link/Debugger
      save_screenshot("#{Zorki.temp_storage_location}/instagram_screenshot_#{SecureRandom.uuid}.png")
    rescue Selenium::WebDriver::Error::TimeoutError
      nil
    end
  end
end

# {"xdt_shortcode_media"=>
#   {"__typename"=>"XDTGraphSidecar",
#    "__isXDTGraphMediaInterface"=>"XDTGraphSidecar",
#    "id"=>"2542603930174846004",
#    "shortcode"=>"CNJJM2elXQ0",
#    "thumbnail_src"=>
#     "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=c82.0.1276.1276a_dst-jpg_e35_s640x640_sh0.08&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYBT02El_YryYIJstdVTLEA-SgPQWiSTqyPIAXfdn2sZKw&oe=6714A2A4&_nc_sid=d885a2",
#    "dimensions"=>{"height"=>957, "width"=>1080},
#    "gating_info"=>nil,
#    "fact_check_overall_rating"=>nil,
#    "fact_check_information"=>nil,
#    "sensitivity_friction_info"=>nil,
#    "sharing_friction_info"=>{"should_have_sharing_friction"=>false, "bloks_app_url"=>nil},
#    "media_overlay_info"=>nil,
#    "media_preview"=>nil,
#    "display_url"=>
#     "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=dst-jpg_e35_s1080x1080&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCqUfuAbAFl8tgRP3hTj9XIv33hCOnm9y-sXLZlAM4zhQ&oe=6714A2A4&_nc_sid=d885a2",
#    "display_resources"=>
#     [{"src"=>
#        "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=dst-jpg_e35_s640x640_sh0.08&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzYuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYBe0iBZl_DMs37jdzJZDgLkWwIuKQKb5OtPFUIooZcORg&oe=6714A2A4&_nc_sid=d885a2",
#       "config_width"=>640,
#       "config_height"=>567},
#      {"src"=>
#        "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=dst-jpg_e35_s750x750_sh0.08&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzYuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAM1JEf70NHUWyBKEQ3VqeZnMW4H5ypDMYCydofcR1eng&oe=6714A2A4&_nc_sid=d885a2",
#       "config_width"=>750,
#       "config_height"=>664},
#      {"src"=>
#        "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=dst-jpg_e35_s1080x1080&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzYuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCqUfuAbAFl8tgRP3hTj9XIv33hCOnm9y-sXLZlAM4zhQ&oe=6714A2A4&_nc_sid=d885a2",
#       "config_width"=>1080,
#       "config_height"=>957}],
#    "is_video"=>false,
#    "tracking_token"=>"eyJ2ZXJzaW9uIjo1LCJwYXlsb2FkIjp7ImlzX2FuYWx5dGljc190cmFja2VkIjp0cnVlLCJ1dWlkIjoiM2FlMTBjMzNmYmRlNDI4NThhMjAzMGU2YzVmYTQwMTcyNTQyNjAzOTMwMTc0ODQ2MDA0In0sInNpZ25hdHVyZSI6IiJ9",
#    "upcoming_event"=>nil,
#    "edge_media_to_tagged_user"=>{"edges"=>[]},
#    "owner"=>
#     {"id"=>"4303258197",
#      "username"=>"petesouza",
#      "is_verified"=>true,
#      "profile_pic_url"=>
#       "https://scontent-lga3-2.cdninstagram.com/v/t51.2885-19/433045134_436644512119229_523706897615373693_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-2.cdninstagram.com&_nc_cat=1&_nc_ohc=N0A8l8Th9soQ7kNvgHfiXc8&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYBoRo6FOu3wh6zZic4B6u9kpJ62u-N09XfGd-BwaLwiOQ&oe=6714B524&_nc_sid=d885a2",
#      "blocked_by_viewer"=>false,
#      "restricted_by_viewer"=>nil,
#      "followed_by_viewer"=>false,
#      "full_name"=>"Pete Souza",
#      "has_blocked_viewer"=>false,
#      "is_embeds_disabled"=>true,
#      "is_private"=>false,
#      "is_unpublished"=>false,
#      "requested_by_viewer"=>false,
#      "pass_tiering_recommendation"=>true,
#      "edge_owner_to_timeline_media"=>{"count"=>3596},
#      "edge_followed_by"=>{"count"=>3166803}},
#    "accessibility_caption"=>"Photo by Pete Souza on April 01, 2021.",
#    "edge_sidecar_to_children"=>
#     {"edges"=>
#       [{"node"=>
#          {"__typename"=>"XDTGraphImage",
#           "id"=>"2542603927029270858",
#           "shortcode"=>"CNJJMzjF8lK",
#           "dimensions"=>{"height"=>957, "width"=>1080},
#           "gating_info"=>nil,
#           "fact_check_overall_rating"=>nil,
#           "fact_check_information"=>nil,
#           "sensitivity_friction_info"=>nil,
#           "sharing_friction_info"=>{"should_have_sharing_friction"=>false, "bloks_app_url"=>nil},
#           "media_overlay_info"=>nil,
#           "media_preview"=>
#            "ACol0JNYjjPKvwcZ49cetWYL5ZwSoYYOOcf0NZF1EAGOM8nI9s8/l1qxpS4jbt82PwFIZr+aPQ0eb7GmiqN/d/ZVXH8RPOM4A9vxpXGld2LzThexpROCM4PNZtjKJoQeTgkEnuc5z+vSryjgfSmIy7jBBGeuRx2puksdjA9cg/n/APXBqgYyXYk929e5/p2q1HL5QwoA4xxSuthpM2t1UNS+aLI+9nA+h6j8cd/51B9qao3uGYYPT0NK47M0ISoiXYAoKg4HHUc1aU8D6VgiZ41Chs4GOnT/ABrSilJRT6gfypoTRrYFGBRRVEhgUYFFFABgUYoooA//2Q==",
#           "display_url"=>
#            "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=dst-jpg_e35_s1080x1080&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCqUfuAbAFl8tgRP3hTj9XIv33hCOnm9y-sXLZlAM4zhQ&oe=6714A2A4&_nc_sid=d885a2",
#           "display_resources"=>
#            [{"src"=>
#               "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=dst-jpg_e35_s640x640_sh0.08&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzYuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYBe0iBZl_DMs37jdzJZDgLkWwIuKQKb5OtPFUIooZcORg&oe=6714A2A4&_nc_sid=d885a2",
#              "config_width"=>640,
#              "config_height"=>567},
#             {"src"=>
#               "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=dst-jpg_e35_s750x750_sh0.08&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzYuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAM1JEf70NHUWyBKEQ3VqeZnMW4H5ypDMYCydofcR1eng&oe=6714A2A4&_nc_sid=d885a2",
#              "config_width"=>750,
#              "config_height"=>664},
#             {"src"=>
#               "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=dst-jpg_e35_s1080x1080&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzYuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCqUfuAbAFl8tgRP3hTj9XIv33hCOnm9y-sXLZlAM4zhQ&oe=6714A2A4&_nc_sid=d885a2",
#              "config_width"=>1080,
#              "config_height"=>957}],
#           "accessibility_caption"=>"Photo by Pete Souza on April 01, 2021.",
#           "is_video"=>false,
#           "tracking_token"=>"eyJ2ZXJzaW9uIjo1LCJwYXlsb2FkIjp7ImlzX2FuYWx5dGljc190cmFja2VkIjp0cnVlLCJ1dWlkIjoiM2FlMTBjMzNmYmRlNDI4NThhMjAzMGU2YzVmYTQwMTcyNTQyNjAzOTI3MDI5MjcwODU4In0sInNpZ25hdHVyZSI6IiJ9",
#           "upcoming_event"=>nil,
#           "edge_media_to_tagged_user"=>{"edges"=>[]}}},
#        {"node"=>
#          {"__typename"=>"XDTGraphImage",
#           "id"=>"2542603927129914635",
#           "shortcode"=>"CNJJMzpF30L",
#           "dimensions"=>{"height"=>957, "width"=>1080},
#           "gating_info"=>nil,
#           "fact_check_overall_rating"=>nil,
#           "fact_check_information"=>nil,
#           "sensitivity_friction_info"=>nil,
#           "sharing_friction_info"=>{"should_have_sharing_friction"=>false, "bloks_app_url"=>nil},
#           "media_overlay_info"=>nil,
#           "media_preview"=>
#            "AColttq7glfLHBI+91wfp3pn9sv/AM8x/wB9H/4muelkKyNgsPmbv7mgTsP4j+IoGdCNb9YyP+BZ/pTv7YP9zHpyf6A1z32huhK/iCKf9p9l/A4oA3f7ZPTav4sR/wCy1cS+LKGwOQD1Pf8ACuY+0+qg/wDAhW1DKDGpx/CO49KAMeSByzHcANxIyPc0wwSjoVI+lWJDJvbBAG49vf603Mnt6/560ubzHoQ/Z36ELz6f0qP7I4OeCKuDf7f57UEtx0BPoT17fh60XGrFTymPIjBH1rchjPlr8mPlHf2rPTePlAHH15/pWvETsXIH3R29qLg7dDRNrCeSi8+wo+yQ/wBxfyFFFFiBRaxDoi/kKX7PF/dX8qKKLDuw+zxf3V/KnCJBwAPyooosF2f/2Q==",
#           "display_url"=>
#            "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166983923_403161454346738_6155203822724328628_n.jpg?stp=dst-jpg_e35_s1080x1080&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=nR5aLOxg9rsQ7kNvgHn_rfh&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAva-GMEQpCXN9L_uSAud5eaV50pfF6PeXY54PcA5SB1Q&oe=6714B630&_nc_sid=d885a2",
#           "display_resources"=>
#            [{"src"=>
#               "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166983923_403161454346738_6155203822724328628_n.jpg?stp=dst-jpg_e35_s640x640_sh0.08&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzcuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=nR5aLOxg9rsQ7kNvgHn_rfh&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYA7id0eta-jnD8lpbi5vSTI5L8_kbtiGVSSKuHOHX1dIw&oe=6714B630&_nc_sid=d885a2",
#              "config_width"=>640,
#              "config_height"=>567},
#             {"src"=>
#               "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166983923_403161454346738_6155203822724328628_n.jpg?stp=dst-jpg_e35_s750x750_sh0.08&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzcuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=nR5aLOxg9rsQ7kNvgHn_rfh&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYA8QEZhXJQlyrEyLJU4czL1D0efUQnksn9B0PsIdhCYsA&oe=6714B630&_nc_sid=d885a2",
#              "config_width"=>750,
#              "config_height"=>665},
#             {"src"=>
#               "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166983923_403161454346738_6155203822724328628_n.jpg?stp=dst-jpg_e35_s1080x1080&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzcuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=nR5aLOxg9rsQ7kNvgHn_rfh&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAva-GMEQpCXN9L_uSAud5eaV50pfF6PeXY54PcA5SB1Q&oe=6714B630&_nc_sid=d885a2",
#              "config_width"=>1080,
#              "config_height"=>957}],
#           "accessibility_caption"=>"Photo by Pete Souza on April 01, 2021.",
#           "is_video"=>false,
#           "tracking_token"=>"eyJ2ZXJzaW9uIjo1LCJwYXlsb2FkIjp7ImlzX2FuYWx5dGljc190cmFja2VkIjp0cnVlLCJ1dWlkIjoiM2FlMTBjMzNmYmRlNDI4NThhMjAzMGU2YzVmYTQwMTcyNTQyNjAzOTI3MTI5OTE0NjM1In0sInNpZ25hdHVyZSI6IiJ9",
#           "upcoming_event"=>nil,
#           "edge_media_to_tagged_user"=>{"edges"=>[]}}},
#        {"node"=>
#          {"__typename"=>"XDTGraphImage",
#           "id"=>"2542603927012387686",
#           "shortcode"=>"CNJJMziFitm",
#           "dimensions"=>{"height"=>957, "width"=>1080},
#           "gating_info"=>nil,
#           "fact_check_overall_rating"=>nil,
#           "fact_check_information"=>nil,
#           "sensitivity_friction_info"=>nil,
#           "sharing_friction_info"=>{"should_have_sharing_friction"=>false, "bloks_app_url"=>nil},
#           "media_overlay_info"=>nil,
#           "media_preview"=>
#            "ACol3DdqDjB/Sk+2L6H9Ko7gxJHPJ/nSGteVEXLpvV9D+lJ9vX0P6f41kyzCJwrfdccH0I9fY/pRNIIkL9fT09qVl9w9dPM1P7QT+636f41Mt0GAODzz2rERhIoYdx29e9aMY+UfQfyoaQXZz5YCQmM4IY9D7n+E/wBKspesvDjd7jg/kcVkyuPMYf7R7+59ac1wSSRwMAAew/n9ai9itOptSSwTDa5468gjH0Pr+lU12RBlP71c8ZOP8896h875Vx8znOQRxgdDwM80nzqpyu9V646jPP8An070pO/qb0rRfvP3bfK/yJkulEgVMhO4Pb/9VdFGuVGPQfyrkFcOx2jBAJyT2FbkDt5a8/wj19KE7aBNKWqd3tfuuh0Hlr6D8hR5aeg/IUUUGAbFHOB+VLtHoKKKAE2L6D8qXaPQUUUAf//Z",
#           "display_url"=>
#            "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/167407336_935009640601058_3247081289383970897_n.jpg?stp=dst-jpg_e35_s1080x1080&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=l64ElxigC_QQ7kNvgGYnpsr&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAUFYVdwSJDrDApXtZ4eYmOl4q4F_CuzJ9ZOn3rsib04Q&oe=6714D767&_nc_sid=d885a2",
#           "display_resources"=>
#            [{"src"=>
#               "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/167407336_935009640601058_3247081289383970897_n.jpg?stp=dst-jpg_e35_s640x640_sh0.08&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzcuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=l64ElxigC_QQ7kNvgGYnpsr&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCjqRYg6KP9TbnQLPvOuNNiutNkc10aAcgL9FjOBg3XTw&oe=6714D767&_nc_sid=d885a2",
#              "config_width"=>640,
#              "config_height"=>567},
#             {"src"=>
#               "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/167407336_935009640601058_3247081289383970897_n.jpg?stp=dst-jpg_e35_s750x750_sh0.08&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzcuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=l64ElxigC_QQ7kNvgGYnpsr&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCw025z1Dlfy5gDzdVft9TlpQWmH8FUegrkjCvG_kOYLQ&oe=6714D767&_nc_sid=d885a2",
#              "config_width"=>750,
#              "config_height"=>665},
#             {"src"=>
#               "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/167407336_935009640601058_3247081289383970897_n.jpg?stp=dst-jpg_e35_s1080x1080&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzcuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=l64ElxigC_QQ7kNvgGYnpsr&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAUFYVdwSJDrDApXtZ4eYmOl4q4F_CuzJ9ZOn3rsib04Q&oe=6714D767&_nc_sid=d885a2",
#              "config_width"=>1080,
#              "config_height"=>957}],
#           "accessibility_caption"=>"Photo by Pete Souza on April 01, 2021.",
#           "is_video"=>false,
#           "tracking_token"=>"eyJ2ZXJzaW9uIjo1LCJwYXlsb2FkIjp7ImlzX2FuYWx5dGljc190cmFja2VkIjp0cnVlLCJ1dWlkIjoiM2FlMTBjMzNmYmRlNDI4NThhMjAzMGU2YzVmYTQwMTcyNTQyNjAzOTI3MDEyMzg3Njg2In0sInNpZ25hdHVyZSI6IiJ9",
#           "upcoming_event"=>nil,
#           "edge_media_to_tagged_user"=>{"edges"=>[]}}}]},
#    "edge_media_to_caption"=>{"edges"=>[{"node"=>{"created_at"=>"1617322030", "text"=>"Opening Day 2010.⁣\n⁣\nSorry that the two teams I follow postponed their games today. (Red Sox because of rain; Nationals because of COVID.)⁣\n⁣", "id"=>"17890677095062000"}}]},
#    "can_see_insights_as_brand"=>false,
#    "caption_is_edited"=>false,
#    "has_ranked_comments"=>false,
#    "like_and_view_counts_disabled"=>false,
#    "edge_media_to_parent_comment"=>
#     {"count"=>188,
#      "page_info"=>{"has_next_page"=>true, "end_cursor"=>"{\"server_cursor\": \"QVFEbkpRYXd0anRYcG5VYndJVEdrNjRJUVB1U1o5T3Q0OGlkcWlkbHI4dkNERHM1SDFzTGR0OFgzbnI0aGlxc2t2ejVWbmZfQzdGWl9JbWFoMW9KSTVnTQ==\", \"is_server_cursor_inverse\": true}"},
#      "edges"=>
#       [{"node"=>
#          {"id"=>"17924110171690039",
#           "text"=>"I hope the Red Sox go into the tank this 2nd half of the season.",
#           "created_at"=>1626326872,
#           "did_report_as_spam"=>false,
#           "owner"=>
#            {"id"=>"7042379789",
#             "is_verified"=>false,
#             "profile_pic_url"=>
#              "https://scontent-lga3-2.cdninstagram.com/v/t51.2885-19/459016393_1045219070578368_7147227732658034012_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-2.cdninstagram.com&_nc_cat=100&_nc_ohc=4sOwhAJlKu0Q7kNvgFOe6dv&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYBg1klj1zemtj23TGeb3v4OkLqv8-vigNP5hBK0RDq_LA&oe=6714C321&_nc_sid=d885a2",
#             "username"=>"arizonacatguy"},
#           "viewer_has_liked"=>false,
#           "edge_liked_by"=>{"count"=>0},
#           "is_restricted_pending"=>false,
#           "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}},
#        {"node"=>
#          {"id"=>"17905180978787101",
#           "text"=>"@happilyheidi_hair",
#           "created_at"=>1619776092,
#           "did_report_as_spam"=>false,
#           "owner"=>
#            {"id"=>"9148384370",
#             "is_verified"=>false,
#             "profile_pic_url"=>
#              "https://scontent-lga3-1.cdninstagram.com/v/t51.2885-19/42995749_186549675612230_3974524660833320960_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=HeT6ZjQJ6ncQ7kNvgGpQzFe&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYB4Bbqc_N1ZY2PT7SpgL54zXFBNMaCTM_Irm2j8qQJZEQ&oe=6714D039&_nc_sid=d885a2",
#             "username"=>"wearekramsey"},
#           "viewer_has_liked"=>false,
#           "edge_liked_by"=>{"count"=>0},
#           "is_restricted_pending"=>false,
#           "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}},
#        {"node"=>
#          {"id"=>"17923749277573891",
#           "text"=>"Love that he is a lefty!!❤️❤️",
#           "created_at"=>1618209072,
#           "did_report_as_spam"=>false,
#           "owner"=>
#            {"id"=>"258728606",
#             "is_verified"=>false,
#             "profile_pic_url"=>
#              "https://scontent-lga3-2.cdninstagram.com/v/t51.2885-19/197380056_677834246349545_1254933075571875966_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-2.cdninstagram.com&_nc_cat=105&_nc_ohc=HIU-_oXrGVQQ7kNvgF6EeKd&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAwkQCUA1jW1DfnXtFpE7Q-tr9Mlafom6bVYPwSMbBivw&oe=6714A9F7&_nc_sid=d885a2",
#             "username"=>"laura_dorfman"},
#           "viewer_has_liked"=>false,
#           "edge_liked_by"=>{"count"=>0},
#           "is_restricted_pending"=>false,
#           "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}},
#        {"node"=>
#          {"id"=>"17906449204808870",
#           "text"=>"That lefty went the distance and will go straight to the hall.",
#           "created_at"=>1617570692,
#           "did_report_as_spam"=>false,
#           "owner"=>
#            {"id"=>"7632902282",
#             "is_verified"=>false,
#             "profile_pic_url"=>
#              "https://scontent-lga3-1.cdninstagram.com/v/t51.2885-19/295264935_2552811661522235_8718279553542030258_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=111&_nc_ohc=aixA_nblIUAQ7kNvgHafN3T&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAtJJCMIZ4KCDrtnJ66sd6jYvyeKkWH1egvZibB8aS9zQ&oe=6714D29A&_nc_sid=d885a2",
#             "username"=>"jamesd7975"},
#           "viewer_has_liked"=>false,
#           "edge_liked_by"=>{"count"=>0},
#           "is_restricted_pending"=>false,
#           "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}},
#        {"node"=>
#          {"id"=>"17872167998303704",
#           "text"=>"Look at that form. Some team could probably still use a good situational lefty pitcher... just saying @barackobama",
#           "created_at"=>1617556697,
#           "did_report_as_spam"=>false,
#           "owner"=>
#            {"id"=>"34924509305",
#             "is_verified"=>false,
#             "profile_pic_url"=>
#              "https://scontent-lga3-1.cdninstagram.com/v/t51.2885-19/96731301_266892211021299_7068954585062178816_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=103&_nc_ohc=O35e0ON1HNIQ7kNvgHNstad&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCkVPkH3XjyGKDguUZ473opbhTaCKPzC4ygXO_BreTpSw&oe=6714C76D&_nc_sid=d885a2",
#             "username"=>"imaseawolf"},
#           "viewer_has_liked"=>false,
#           "edge_liked_by"=>{"count"=>0},
#           "is_restricted_pending"=>false,
#           "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}},
#        {"node"=>
#          {"id"=>"17886631661056960",
#           "text"=>"He’s just the best",
#           "created_at"=>1617493051,
#           "did_report_as_spam"=>false,
#           "owner"=>
#            {"id"=>"20023550998",
#             "is_verified"=>false,
#             "profile_pic_url"=>
#              "https://scontent-lga3-2.cdninstagram.com/v/t51.2885-19/128591447_196956778589124_3534405417661406210_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-2.cdninstagram.com&_nc_cat=100&_nc_ohc=9lAgJaFHUf8Q7kNvgFczW_W&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYC3XjGdjIATXjF7-mo4ihHiZgnWQI5J_nJHq0gSIq8kcw&oe=6714C45A&_nc_sid=d885a2",
#             "username"=>"teebrunetti"},
#           "viewer_has_liked"=>false,
#           "edge_liked_by"=>{"count"=>0},
#           "is_restricted_pending"=>false,
#           "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}},
#        {"node"=>
#          {"id"=>"17927640088542827",
#           "text"=>"😍😍😍",
#           "created_at"=>1617481695,
#           "did_report_as_spam"=>false,
#           "owner"=>
#            {"id"=>"3029469755",
#             "is_verified"=>false,
#             "profile_pic_url"=>
#              "https://scontent-lga3-2.cdninstagram.com/v/t51.2885-19/53098740_235646934057457_5873090442651762688_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-2.cdninstagram.com&_nc_cat=101&_nc_ohc=b-AN4puNDQ8Q7kNvgGbhdFz&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCG_6-DN9a-Ri-BalnNLlEpWzWv8fFpPryly3eaxuBBJw&oe=6714BE90&_nc_sid=d885a2",
#             "username"=>"lu2yen"},
#           "viewer_has_liked"=>false,
#           "edge_liked_by"=>{"count"=>0},
#           "is_restricted_pending"=>false,
#           "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}},
#        {"node"=>
#          {"id"=>"17881824170123456",
#           "text"=>"Love this guy!",
#           "created_at"=>1617465947,
#           "did_report_as_spam"=>false,
#           "owner"=>
#            {"id"=>"2195211531",
#             "is_verified"=>false,
#             "profile_pic_url"=>
#              "https://scontent-lga3-1.cdninstagram.com/v/t51.2885-19/10268793_852764404831414_583783631_a.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=JO7MghX3sjMQ7kNvgG01D20&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAQzDuiV_Cry8rJcBI1UD47qWAijx9c9iARdisWtjzF9g&oe=6714AE78&_nc_sid=d885a2",
#             "username"=>"d.c.emanuele"},
#           "viewer_has_liked"=>false,
#           "edge_liked_by"=>{"count"=>1},
#           "is_restricted_pending"=>false,
#           "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}},
#        {"node"=>
#          {"id"=>"17861618138460884",
#           "text"=>"Hard to outdo that guy for a long, long time.",
#           "created_at"=>1617464062,
#           "did_report_as_spam"=>false,
#           "owner"=>
#            {"id"=>"5662650501",
#             "is_verified"=>false,
#             "profile_pic_url"=>
#              "https://scontent-lga3-2.cdninstagram.com/v/t51.2885-19/47692139_2217417935165851_4146156738007007232_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-2.cdninstagram.com&_nc_cat=107&_nc_ohc=iUYMrldKk8YQ7kNvgGJe-D2&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCq6bG3I2-ZkJuVIfj4HJdp21YLDN7RUYVwBYaanBhd9A&oe=6714BF63&_nc_sid=d885a2",
#             "username"=>"chrismichel7144"},
#           "viewer_has_liked"=>false,
#           "edge_liked_by"=>{"count"=>1},
#           "is_restricted_pending"=>false,
#           "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}}]},
#    "edge_media_to_hoisted_comment"=>{"edges"=>[]},
#    "edge_media_preview_comment"=>
#     {"count"=>188,
#      "edges"=>
#       [{"node"=>
#          {"id"=>"17905180978787101",
#           "text"=>"@happilyheidi_hair",
#           "created_at"=>1619776092,
#           "did_report_as_spam"=>false,
#           "owner"=>
#            {"id"=>"9148384370",
#             "is_verified"=>false,
#             "profile_pic_url"=>
#              "https://scontent-lga3-1.cdninstagram.com/v/t51.2885-19/42995749_186549675612230_3974524660833320960_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=HeT6ZjQJ6ncQ7kNvgGpQzFe&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYB4Bbqc_N1ZY2PT7SpgL54zXFBNMaCTM_Irm2j8qQJZEQ&oe=6714D039&_nc_sid=d885a2",
#             "username"=>"wearekramsey"},
#           "viewer_has_liked"=>false,
#           "edge_liked_by"=>{"count"=>0},
#           "is_restricted_pending"=>false}},
#        {"node"=>
#          {"id"=>"17924110171690039",
#           "text"=>"I hope the Red Sox go into the tank this 2nd half of the season.",
#           "created_at"=>1626326872,
#           "did_report_as_spam"=>false,
#           "owner"=>
#            {"id"=>"7042379789",
#             "is_verified"=>false,
#             "profile_pic_url"=>
#              "https://scontent-lga3-2.cdninstagram.com/v/t51.2885-19/459016393_1045219070578368_7147227732658034012_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-2.cdninstagram.com&_nc_cat=100&_nc_ohc=4sOwhAJlKu0Q7kNvgFOe6dv&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYBg1klj1zemtj23TGeb3v4OkLqv8-vigNP5hBK0RDq_LA&oe=6714C321&_nc_sid=d885a2",
#             "username"=>"arizonacatguy"},
#           "viewer_has_liked"=>false,
#           "edge_liked_by"=>{"count"=>0},
#           "is_restricted_pending"=>false}}]},
#    "comments_disabled"=>false,
#    "commenting_disabled_for_viewer"=>false,
#    "taken_at_timestamp"=>1617322029,
#    "edge_media_preview_like"=>{"count"=>41388, "edges"=>[]},
#    "edge_media_to_sponsor_user"=>{"edges"=>[]},
#    "is_affiliate"=>false,
#    "is_paid_partnership"=>false,
#    "location"=>
#     {"id"=>"235453813",
#      "has_public_page"=>true,
#      "name"=>"Nationals Park",
#      "slug"=>"nationals-park",
#      "address_json"=>"{\"street_address\": \"1500 S Capitol St SE\", \"zip_code\": \"20003\", \"city_name\": \"Washington D.C.\", \"region_name\": \"\", \"country_code\": \"\", \"exact_city_match\": false, \"exact_region_match\": false, \"exact_country_match\": false}"},
#    "nft_asset_info"=>nil,
#    "viewer_has_liked"=>false,
#    "viewer_has_saved"=>false,
#    "viewer_has_saved_to_collection"=>false,
#    "viewer_in_photo_of_you"=>false,
#    "viewer_can_reshare"=>true,
#    "is_ad"=>false,
#    "edge_web_media_to_related_media"=>{"edges"=>[]},
#    "coauthor_producers"=>[],
#    "pinned_for_users"=>[]}}
# (ruby) graphql_object["data"].keys
# ["xdt_shortcode_media"]
# (ruby) graphql_object["data"]["xdt_shortcode_media"]
# {"__typename"=>"XDTGraphSidecar",
#  "__isXDTGraphMediaInterface"=>"XDTGraphSidecar",
#  "id"=>"2542603930174846004",
#  "shortcode"=>"CNJJM2elXQ0",
#  "thumbnail_src"=>
#   "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=c82.0.1276.1276a_dst-jpg_e35_s640x640_sh0.08&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYBT02El_YryYIJstdVTLEA-SgPQWiSTqyPIAXfdn2sZKw&oe=6714A2A4&_nc_sid=d885a2",
#  "dimensions"=>{"height"=>957, "width"=>1080},
#  "gating_info"=>nil,
#  "fact_check_overall_rating"=>nil,
#  "fact_check_information"=>nil,
#  "sensitivity_friction_info"=>nil,
#  "sharing_friction_info"=>{"should_have_sharing_friction"=>false, "bloks_app_url"=>nil},
#  "media_overlay_info"=>nil,
#  "media_preview"=>nil,
#  "display_url"=>
#   "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=dst-jpg_e35_s1080x1080&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCqUfuAbAFl8tgRP3hTj9XIv33hCOnm9y-sXLZlAM4zhQ&oe=6714A2A4&_nc_sid=d885a2",
#  "display_resources"=>
#   [{"src"=>
#      "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=dst-jpg_e35_s640x640_sh0.08&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzYuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYBe0iBZl_DMs37jdzJZDgLkWwIuKQKb5OtPFUIooZcORg&oe=6714A2A4&_nc_sid=d885a2",
#     "config_width"=>640,
#     "config_height"=>567},
#    {"src"=>
#      "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=dst-jpg_e35_s750x750_sh0.08&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzYuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAM1JEf70NHUWyBKEQ3VqeZnMW4H5ypDMYCydofcR1eng&oe=6714A2A4&_nc_sid=d885a2",
#     "config_width"=>750,
#     "config_height"=>664},
#    {"src"=>
#      "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=dst-jpg_e35_s1080x1080&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzYuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCqUfuAbAFl8tgRP3hTj9XIv33hCOnm9y-sXLZlAM4zhQ&oe=6714A2A4&_nc_sid=d885a2",
#     "config_width"=>1080,
#     "config_height"=>957}],
#  "is_video"=>false,
#  "tracking_token"=>"eyJ2ZXJzaW9uIjo1LCJwYXlsb2FkIjp7ImlzX2FuYWx5dGljc190cmFja2VkIjp0cnVlLCJ1dWlkIjoiM2FlMTBjMzNmYmRlNDI4NThhMjAzMGU2YzVmYTQwMTcyNTQyNjAzOTMwMTc0ODQ2MDA0In0sInNpZ25hdHVyZSI6IiJ9",
#  "upcoming_event"=>nil,
#  "edge_media_to_tagged_user"=>{"edges"=>[]},
#  "owner"=>
#   {"id"=>"4303258197",
#    "username"=>"petesouza",
#    "is_verified"=>true,
#    "profile_pic_url"=>
#     "https://scontent-lga3-2.cdninstagram.com/v/t51.2885-19/433045134_436644512119229_523706897615373693_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-2.cdninstagram.com&_nc_cat=1&_nc_ohc=N0A8l8Th9soQ7kNvgHfiXc8&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYBoRo6FOu3wh6zZic4B6u9kpJ62u-N09XfGd-BwaLwiOQ&oe=6714B524&_nc_sid=d885a2",
#    "blocked_by_viewer"=>false,
#    "restricted_by_viewer"=>nil,
#    "followed_by_viewer"=>false,
#    "full_name"=>"Pete Souza",
#    "has_blocked_viewer"=>false,
#    "is_embeds_disabled"=>true,
#    "is_private"=>false,
#    "is_unpublished"=>false,
#    "requested_by_viewer"=>false,
#    "pass_tiering_recommendation"=>true,
#    "edge_owner_to_timeline_media"=>{"count"=>3596},
#    "edge_followed_by"=>{"count"=>3166803}},
#  "accessibility_caption"=>"Photo by Pete Souza on April 01, 2021.",
#  "edge_sidecar_to_children"=>
#   {"edges"=>
#     [{"node"=>
#        {"__typename"=>"XDTGraphImage",
#         "id"=>"2542603927029270858",
#         "shortcode"=>"CNJJMzjF8lK",
#         "dimensions"=>{"height"=>957, "width"=>1080},
#         "gating_info"=>nil,
#         "fact_check_overall_rating"=>nil,
#         "fact_check_information"=>nil,
#         "sensitivity_friction_info"=>nil,
#         "sharing_friction_info"=>{"should_have_sharing_friction"=>false, "bloks_app_url"=>nil},
#         "media_overlay_info"=>nil,
#         "media_preview"=>
#          "ACol0JNYjjPKvwcZ49cetWYL5ZwSoYYOOcf0NZF1EAGOM8nI9s8/l1qxpS4jbt82PwFIZr+aPQ0eb7GmiqN/d/ZVXH8RPOM4A9vxpXGld2LzThexpROCM4PNZtjKJoQeTgkEnuc5z+vSryjgfSmIy7jBBGeuRx2puksdjA9cg/n/APXBqgYyXYk929e5/p2q1HL5QwoA4xxSuthpM2t1UNS+aLI+9nA+h6j8cd/51B9qao3uGYYPT0NK47M0ISoiXYAoKg4HHUc1aU8D6VgiZ41Chs4GOnT/ABrSilJRT6gfypoTRrYFGBRRVEhgUYFFFABgUYoooA//2Q==",
#         "display_url"=>
#          "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=dst-jpg_e35_s1080x1080&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCqUfuAbAFl8tgRP3hTj9XIv33hCOnm9y-sXLZlAM4zhQ&oe=6714A2A4&_nc_sid=d885a2",
#         "display_resources"=>
#          [{"src"=>
#             "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=dst-jpg_e35_s640x640_sh0.08&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzYuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYBe0iBZl_DMs37jdzJZDgLkWwIuKQKb5OtPFUIooZcORg&oe=6714A2A4&_nc_sid=d885a2",
#            "config_width"=>640,
#            "config_height"=>567},
#           {"src"=>
#             "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=dst-jpg_e35_s750x750_sh0.08&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzYuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAM1JEf70NHUWyBKEQ3VqeZnMW4H5ypDMYCydofcR1eng&oe=6714A2A4&_nc_sid=d885a2",
#            "config_width"=>750,
#            "config_height"=>664},
#           {"src"=>
#             "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166780469_489667965807274_3707647015587575071_n.jpg?stp=dst-jpg_e35_s1080x1080&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzYuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=in9T9HwRz9QQ7kNvgH8bokx&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCqUfuAbAFl8tgRP3hTj9XIv33hCOnm9y-sXLZlAM4zhQ&oe=6714A2A4&_nc_sid=d885a2",
#            "config_width"=>1080,
#            "config_height"=>957}],
#         "accessibility_caption"=>"Photo by Pete Souza on April 01, 2021.",
#         "is_video"=>false,
#         "tracking_token"=>"eyJ2ZXJzaW9uIjo1LCJwYXlsb2FkIjp7ImlzX2FuYWx5dGljc190cmFja2VkIjp0cnVlLCJ1dWlkIjoiM2FlMTBjMzNmYmRlNDI4NThhMjAzMGU2YzVmYTQwMTcyNTQyNjAzOTI3MDI5MjcwODU4In0sInNpZ25hdHVyZSI6IiJ9",
#         "upcoming_event"=>nil,
#         "edge_media_to_tagged_user"=>{"edges"=>[]}}},
#      {"node"=>
#        {"__typename"=>"XDTGraphImage",
#         "id"=>"2542603927129914635",
#         "shortcode"=>"CNJJMzpF30L",
#         "dimensions"=>{"height"=>957, "width"=>1080},
#         "gating_info"=>nil,
#         "fact_check_overall_rating"=>nil,
#         "fact_check_information"=>nil,
#         "sensitivity_friction_info"=>nil,
#         "sharing_friction_info"=>{"should_have_sharing_friction"=>false, "bloks_app_url"=>nil},
#         "media_overlay_info"=>nil,
#         "media_preview"=>
#          "AColttq7glfLHBI+91wfp3pn9sv/AM8x/wB9H/4muelkKyNgsPmbv7mgTsP4j+IoGdCNb9YyP+BZ/pTv7YP9zHpyf6A1z32huhK/iCKf9p9l/A4oA3f7ZPTav4sR/wCy1cS+LKGwOQD1Pf8ACuY+0+qg/wDAhW1DKDGpx/CO49KAMeSByzHcANxIyPc0wwSjoVI+lWJDJvbBAG49vf603Mnt6/560ubzHoQ/Z36ELz6f0qP7I4OeCKuDf7f57UEtx0BPoT17fh60XGrFTymPIjBH1rchjPlr8mPlHf2rPTePlAHH15/pWvETsXIH3R29qLg7dDRNrCeSi8+wo+yQ/wBxfyFFFFiBRaxDoi/kKX7PF/dX8qKKLDuw+zxf3V/KnCJBwAPyooosF2f/2Q==",
#         "display_url"=>
#          "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166983923_403161454346738_6155203822724328628_n.jpg?stp=dst-jpg_e35_s1080x1080&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=nR5aLOxg9rsQ7kNvgHn_rfh&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAva-GMEQpCXN9L_uSAud5eaV50pfF6PeXY54PcA5SB1Q&oe=6714B630&_nc_sid=d885a2",
#         "display_resources"=>
#          [{"src"=>
#             "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166983923_403161454346738_6155203822724328628_n.jpg?stp=dst-jpg_e35_s640x640_sh0.08&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzcuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=nR5aLOxg9rsQ7kNvgHn_rfh&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYA7id0eta-jnD8lpbi5vSTI5L8_kbtiGVSSKuHOHX1dIw&oe=6714B630&_nc_sid=d885a2",
#            "config_width"=>640,
#            "config_height"=>567},
#           {"src"=>
#             "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166983923_403161454346738_6155203822724328628_n.jpg?stp=dst-jpg_e35_s750x750_sh0.08&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzcuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=nR5aLOxg9rsQ7kNvgHn_rfh&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYA8QEZhXJQlyrEyLJU4czL1D0efUQnksn9B0PsIdhCYsA&oe=6714B630&_nc_sid=d885a2",
#            "config_width"=>750,
#            "config_height"=>665},
#           {"src"=>
#             "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/166983923_403161454346738_6155203822724328628_n.jpg?stp=dst-jpg_e35_s1080x1080&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzcuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=nR5aLOxg9rsQ7kNvgHn_rfh&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAva-GMEQpCXN9L_uSAud5eaV50pfF6PeXY54PcA5SB1Q&oe=6714B630&_nc_sid=d885a2",
#            "config_width"=>1080,
#            "config_height"=>957}],
#         "accessibility_caption"=>"Photo by Pete Souza on April 01, 2021.",
#         "is_video"=>false,
#         "tracking_token"=>"eyJ2ZXJzaW9uIjo1LCJwYXlsb2FkIjp7ImlzX2FuYWx5dGljc190cmFja2VkIjp0cnVlLCJ1dWlkIjoiM2FlMTBjMzNmYmRlNDI4NThhMjAzMGU2YzVmYTQwMTcyNTQyNjAzOTI3MTI5OTE0NjM1In0sInNpZ25hdHVyZSI6IiJ9",
#         "upcoming_event"=>nil,
#         "edge_media_to_tagged_user"=>{"edges"=>[]}}},
#      {"node"=>
#        {"__typename"=>"XDTGraphImage",
#         "id"=>"2542603927012387686",
#         "shortcode"=>"CNJJMziFitm",
#         "dimensions"=>{"height"=>957, "width"=>1080},
#         "gating_info"=>nil,
#         "fact_check_overall_rating"=>nil,
#         "fact_check_information"=>nil,
#         "sensitivity_friction_info"=>nil,
#         "sharing_friction_info"=>{"should_have_sharing_friction"=>false, "bloks_app_url"=>nil},
#         "media_overlay_info"=>nil,
#         "media_preview"=>
#          "ACol3DdqDjB/Sk+2L6H9Ko7gxJHPJ/nSGteVEXLpvV9D+lJ9vX0P6f41kyzCJwrfdccH0I9fY/pRNIIkL9fT09qVl9w9dPM1P7QT+636f41Mt0GAODzz2rERhIoYdx29e9aMY+UfQfyoaQXZz5YCQmM4IY9D7n+E/wBKspesvDjd7jg/kcVkyuPMYf7R7+59ac1wSSRwMAAew/n9ai9itOptSSwTDa5468gjH0Pr+lU12RBlP71c8ZOP8896h875Vx8znOQRxgdDwM80nzqpyu9V646jPP8An070pO/qb0rRfvP3bfK/yJkulEgVMhO4Pb/9VdFGuVGPQfyrkFcOx2jBAJyT2FbkDt5a8/wj19KE7aBNKWqd3tfuuh0Hlr6D8hR5aeg/IUUUGAbFHOB+VLtHoKKKAE2L6D8qXaPQUUUAf//Z",
#         "display_url"=>
#          "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/167407336_935009640601058_3247081289383970897_n.jpg?stp=dst-jpg_e35_s1080x1080&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=l64ElxigC_QQ7kNvgGYnpsr&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAUFYVdwSJDrDApXtZ4eYmOl4q4F_CuzJ9ZOn3rsib04Q&oe=6714D767&_nc_sid=d885a2",
#         "display_resources"=>
#          [{"src"=>
#             "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/167407336_935009640601058_3247081289383970897_n.jpg?stp=dst-jpg_e35_s640x640_sh0.08&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzcuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=l64ElxigC_QQ7kNvgGYnpsr&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCjqRYg6KP9TbnQLPvOuNNiutNkc10aAcgL9FjOBg3XTw&oe=6714D767&_nc_sid=d885a2",
#            "config_width"=>640,
#            "config_height"=>567},
#           {"src"=>
#             "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/167407336_935009640601058_3247081289383970897_n.jpg?stp=dst-jpg_e35_s750x750_sh0.08&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzcuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=l64ElxigC_QQ7kNvgGYnpsr&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCw025z1Dlfy5gDzdVft9TlpQWmH8FUegrkjCvG_kOYLQ&oe=6714D767&_nc_sid=d885a2",
#            "config_width"=>750,
#            "config_height"=>665},
#           {"src"=>
#             "https://scontent-lga3-1.cdninstagram.com/v/t51.29350-15/167407336_935009640601058_3247081289383970897_n.jpg?stp=dst-jpg_e35_s1080x1080&efg=eyJ2ZW5jb2RlX3RhZyI6ImltYWdlX3VybGdlbi4xNDQweDEyNzcuc2RyLmYyOTM1MC5kZWZhdWx0X2ltYWdlIn0&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=l64ElxigC_QQ7kNvgGYnpsr&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAUFYVdwSJDrDApXtZ4eYmOl4q4F_CuzJ9ZOn3rsib04Q&oe=6714D767&_nc_sid=d885a2",
#            "config_width"=>1080,
#            "config_height"=>957}],
#         "accessibility_caption"=>"Photo by Pete Souza on April 01, 2021.",
#         "is_video"=>false,
#         "tracking_token"=>"eyJ2ZXJzaW9uIjo1LCJwYXlsb2FkIjp7ImlzX2FuYWx5dGljc190cmFja2VkIjp0cnVlLCJ1dWlkIjoiM2FlMTBjMzNmYmRlNDI4NThhMjAzMGU2YzVmYTQwMTcyNTQyNjAzOTI3MDEyMzg3Njg2In0sInNpZ25hdHVyZSI6IiJ9",
#         "upcoming_event"=>nil,
#         "edge_media_to_tagged_user"=>{"edges"=>[]}}}]},
#  "edge_media_to_caption"=>{"edges"=>[{"node"=>{"created_at"=>"1617322030", "text"=>"Opening Day 2010.⁣\n⁣\nSorry that the two teams I follow postponed their games today. (Red Sox because of rain; Nationals because of COVID.)⁣\n⁣", "id"=>"17890677095062000"}}]},
#  "can_see_insights_as_brand"=>false,
#  "caption_is_edited"=>false,
#  "has_ranked_comments"=>false,
#  "like_and_view_counts_disabled"=>false,
#  "edge_media_to_parent_comment"=>
#   {"count"=>188,
#    "page_info"=>{"has_next_page"=>true, "end_cursor"=>"{\"server_cursor\": \"QVFEbkpRYXd0anRYcG5VYndJVEdrNjRJUVB1U1o5T3Q0OGlkcWlkbHI4dkNERHM1SDFzTGR0OFgzbnI0aGlxc2t2ejVWbmZfQzdGWl9JbWFoMW9KSTVnTQ==\", \"is_server_cursor_inverse\": true}"},
#    "edges"=>
#     [{"node"=>
#        {"id"=>"17924110171690039",
#         "text"=>"I hope the Red Sox go into the tank this 2nd half of the season.",
#         "created_at"=>1626326872,
#         "did_report_as_spam"=>false,
#         "owner"=>
#          {"id"=>"7042379789",
#           "is_verified"=>false,
#           "profile_pic_url"=>
#            "https://scontent-lga3-2.cdninstagram.com/v/t51.2885-19/459016393_1045219070578368_7147227732658034012_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-2.cdninstagram.com&_nc_cat=100&_nc_ohc=4sOwhAJlKu0Q7kNvgFOe6dv&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYBg1klj1zemtj23TGeb3v4OkLqv8-vigNP5hBK0RDq_LA&oe=6714C321&_nc_sid=d885a2",
#           "username"=>"arizonacatguy"},
#         "viewer_has_liked"=>false,
#         "edge_liked_by"=>{"count"=>0},
#         "is_restricted_pending"=>false,
#         "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}},
#      {"node"=>
#        {"id"=>"17905180978787101",
#         "text"=>"@happilyheidi_hair",
#         "created_at"=>1619776092,
#         "did_report_as_spam"=>false,
#         "owner"=>
#          {"id"=>"9148384370",
#           "is_verified"=>false,
#           "profile_pic_url"=>
#            "https://scontent-lga3-1.cdninstagram.com/v/t51.2885-19/42995749_186549675612230_3974524660833320960_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=HeT6ZjQJ6ncQ7kNvgGpQzFe&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYB4Bbqc_N1ZY2PT7SpgL54zXFBNMaCTM_Irm2j8qQJZEQ&oe=6714D039&_nc_sid=d885a2",
#           "username"=>"wearekramsey"},
#         "viewer_has_liked"=>false,
#         "edge_liked_by"=>{"count"=>0},
#         "is_restricted_pending"=>false,
#         "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}},
#      {"node"=>
#        {"id"=>"17923749277573891",
#         "text"=>"Love that he is a lefty!!❤️❤️",
#         "created_at"=>1618209072,
#         "did_report_as_spam"=>false,
#         "owner"=>
#          {"id"=>"258728606",
#           "is_verified"=>false,
#           "profile_pic_url"=>
#            "https://scontent-lga3-2.cdninstagram.com/v/t51.2885-19/197380056_677834246349545_1254933075571875966_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-2.cdninstagram.com&_nc_cat=105&_nc_ohc=HIU-_oXrGVQQ7kNvgF6EeKd&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAwkQCUA1jW1DfnXtFpE7Q-tr9Mlafom6bVYPwSMbBivw&oe=6714A9F7&_nc_sid=d885a2",
#           "username"=>"laura_dorfman"},
#         "viewer_has_liked"=>false,
#         "edge_liked_by"=>{"count"=>0},
#         "is_restricted_pending"=>false,
#         "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}},
#      {"node"=>
#        {"id"=>"17906449204808870",
#         "text"=>"That lefty went the distance and will go straight to the hall.",
#         "created_at"=>1617570692,
#         "did_report_as_spam"=>false,
#         "owner"=>
#          {"id"=>"7632902282",
#           "is_verified"=>false,
#           "profile_pic_url"=>
#            "https://scontent-lga3-1.cdninstagram.com/v/t51.2885-19/295264935_2552811661522235_8718279553542030258_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=111&_nc_ohc=aixA_nblIUAQ7kNvgHafN3T&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAtJJCMIZ4KCDrtnJ66sd6jYvyeKkWH1egvZibB8aS9zQ&oe=6714D29A&_nc_sid=d885a2",
#           "username"=>"jamesd7975"},
#         "viewer_has_liked"=>false,
#         "edge_liked_by"=>{"count"=>0},
#         "is_restricted_pending"=>false,
#         "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}},
#      {"node"=>
#        {"id"=>"17872167998303704",
#         "text"=>"Look at that form. Some team could probably still use a good situational lefty pitcher... just saying @barackobama",
#         "created_at"=>1617556697,
#         "did_report_as_spam"=>false,
#         "owner"=>
#          {"id"=>"34924509305",
#           "is_verified"=>false,
#           "profile_pic_url"=>
#            "https://scontent-lga3-1.cdninstagram.com/v/t51.2885-19/96731301_266892211021299_7068954585062178816_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=103&_nc_ohc=O35e0ON1HNIQ7kNvgHNstad&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCkVPkH3XjyGKDguUZ473opbhTaCKPzC4ygXO_BreTpSw&oe=6714C76D&_nc_sid=d885a2",
#           "username"=>"imaseawolf"},
#         "viewer_has_liked"=>false,
#         "edge_liked_by"=>{"count"=>0},
#         "is_restricted_pending"=>false,
#         "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}},
#      {"node"=>
#        {"id"=>"17886631661056960",
#         "text"=>"He’s just the best",
#         "created_at"=>1617493051,
#         "did_report_as_spam"=>false,
#         "owner"=>
#          {"id"=>"20023550998",
#           "is_verified"=>false,
#           "profile_pic_url"=>
#            "https://scontent-lga3-2.cdninstagram.com/v/t51.2885-19/128591447_196956778589124_3534405417661406210_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-2.cdninstagram.com&_nc_cat=100&_nc_ohc=9lAgJaFHUf8Q7kNvgFczW_W&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYC3XjGdjIATXjF7-mo4ihHiZgnWQI5J_nJHq0gSIq8kcw&oe=6714C45A&_nc_sid=d885a2",
#           "username"=>"teebrunetti"},
#         "viewer_has_liked"=>false,
#         "edge_liked_by"=>{"count"=>0},
#         "is_restricted_pending"=>false,
#         "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}},
#      {"node"=>
#        {"id"=>"17927640088542827",
#         "text"=>"😍😍😍",
#         "created_at"=>1617481695,
#         "did_report_as_spam"=>false,
#         "owner"=>
#          {"id"=>"3029469755",
#           "is_verified"=>false,
#           "profile_pic_url"=>
#            "https://scontent-lga3-2.cdninstagram.com/v/t51.2885-19/53098740_235646934057457_5873090442651762688_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-2.cdninstagram.com&_nc_cat=101&_nc_ohc=b-AN4puNDQ8Q7kNvgGbhdFz&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCG_6-DN9a-Ri-BalnNLlEpWzWv8fFpPryly3eaxuBBJw&oe=6714BE90&_nc_sid=d885a2",
#           "username"=>"lu2yen"},
#         "viewer_has_liked"=>false,
#         "edge_liked_by"=>{"count"=>0},
#         "is_restricted_pending"=>false,
#         "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}},
#      {"node"=>
#        {"id"=>"17881824170123456",
#         "text"=>"Love this guy!",
#         "created_at"=>1617465947,
#         "did_report_as_spam"=>false,
#         "owner"=>
#          {"id"=>"2195211531",
#           "is_verified"=>false,
#           "profile_pic_url"=>
#            "https://scontent-lga3-1.cdninstagram.com/v/t51.2885-19/10268793_852764404831414_583783631_a.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=110&_nc_ohc=JO7MghX3sjMQ7kNvgG01D20&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYAQzDuiV_Cry8rJcBI1UD47qWAijx9c9iARdisWtjzF9g&oe=6714AE78&_nc_sid=d885a2",
#           "username"=>"d.c.emanuele"},
#         "viewer_has_liked"=>false,
#         "edge_liked_by"=>{"count"=>1},
#         "is_restricted_pending"=>false,
#         "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}},
#      {"node"=>
#        {"id"=>"17861618138460884",
#         "text"=>"Hard to outdo that guy for a long, long time.",
#         "created_at"=>1617464062,
#         "did_report_as_spam"=>false,
#         "owner"=>
#          {"id"=>"5662650501",
#           "is_verified"=>false,
#           "profile_pic_url"=>
#            "https://scontent-lga3-2.cdninstagram.com/v/t51.2885-19/47692139_2217417935165851_4146156738007007232_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-2.cdninstagram.com&_nc_cat=107&_nc_ohc=iUYMrldKk8YQ7kNvgGJe-D2&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYCq6bG3I2-ZkJuVIfj4HJdp21YLDN7RUYVwBYaanBhd9A&oe=6714BF63&_nc_sid=d885a2",
#           "username"=>"chrismichel7144"},
#         "viewer_has_liked"=>false,
#         "edge_liked_by"=>{"count"=>1},
#         "is_restricted_pending"=>false,
#         "edge_threaded_comments"=>{"count"=>0, "page_info"=>{"has_next_page"=>false, "end_cursor"=>nil}, "edges"=>[]}}}]},
#  "edge_media_to_hoisted_comment"=>{"edges"=>[]},
#  "edge_media_preview_comment"=>
#   {"count"=>188,
#    "edges"=>
#     [{"node"=>
#        {"id"=>"17905180978787101",
#         "text"=>"@happilyheidi_hair",
#         "created_at"=>1619776092,
#         "did_report_as_spam"=>false,
#         "owner"=>
#          {"id"=>"9148384370",
#           "is_verified"=>false,
#           "profile_pic_url"=>
#            "https://scontent-lga3-1.cdninstagram.com/v/t51.2885-19/42995749_186549675612230_3974524660833320960_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-1.cdninstagram.com&_nc_cat=102&_nc_ohc=HeT6ZjQJ6ncQ7kNvgGpQzFe&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYB4Bbqc_N1ZY2PT7SpgL54zXFBNMaCTM_Irm2j8qQJZEQ&oe=6714D039&_nc_sid=d885a2",
#           "username"=>"wearekramsey"},
#         "viewer_has_liked"=>false,
#         "edge_liked_by"=>{"count"=>0},
#         "is_restricted_pending"=>false}},
#      {"node"=>
#        {"id"=>"17924110171690039",
#         "text"=>"I hope the Red Sox go into the tank this 2nd half of the season.",
#         "created_at"=>1626326872,
#         "did_report_as_spam"=>false,
#         "owner"=>
#          {"id"=>"7042379789",
#           "is_verified"=>false,
#           "profile_pic_url"=>
#            "https://scontent-lga3-2.cdninstagram.com/v/t51.2885-19/459016393_1045219070578368_7147227732658034012_n.jpg?stp=dst-jpg_s150x150&_nc_ht=scontent-lga3-2.cdninstagram.com&_nc_cat=100&_nc_ohc=4sOwhAJlKu0Q7kNvgFOe6dv&_nc_gid=3ae10c33fbde42858a2030e6c5fa4017&edm=ANTKIIoBAAAA&ccb=7-5&oh=00_AYBg1klj1zemtj23TGeb3v4OkLqv8-vigNP5hBK0RDq_LA&oe=6714C321&_nc_sid=d885a2",
#           "username"=>"arizonacatguy"},
#         "viewer_has_liked"=>false,
#         "edge_liked_by"=>{"count"=>0},
#         "is_restricted_pending"=>false}}]},
#  "comments_disabled"=>false,
#  "commenting_disabled_for_viewer"=>false,
#  "taken_at_timestamp"=>1617322029,
#  "edge_media_preview_like"=>{"count"=>41388, "edges"=>[]},
#  "edge_media_to_sponsor_user"=>{"edges"=>[]},
#  "is_affiliate"=>false,
#  "is_paid_partnership"=>false,
#  "location"=>
#   {"id"=>"235453813",
#    "has_public_page"=>true,
#    "name"=>"Nationals Park",
#    "slug"=>"nationals-park",
#    "address_json"=>"{\"street_address\": \"1500 S Capitol St SE\", \"zip_code\": \"20003\", \"city_name\": \"Washington D.C.\", \"region_name\": \"\", \"country_code\": \"\", \"exact_city_match\": false, \"exact_region_match\": false, \"exact_country_match\": false}"},
#  "nft_asset_info"=>nil,
#  "viewer_has_liked"=>false,
#  "viewer_has_saved"=>false,
#  "viewer_has_saved_to_collection"=>false,
#  "viewer_in_photo_of_you"=>false,
#  "viewer_can_reshare"=>true,
#  "is_ad"=>false,
#  "edge_web_media_to_related_media"=>{"edges"=>[]},
#  "coauthor_producers"=>[],
#  "pinned_for_users"=>[]}
