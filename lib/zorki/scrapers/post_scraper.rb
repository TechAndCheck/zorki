# frozen_string_literal: true

require "typhoeus"

module Zorki
  class PostScraper < Scraper
    def parse(id)
      # Stuff we need to get from the DOM (implemented is starred):
      # - User *
      # - Text *
      # - Image * / Images * / Video *
      # - Date *
      # - Number of likes *
      # - Hashtags

      Capybara.app_host = "https://instagram.com"

      # video slideshows https://www.instagram.com/p/CY7KxwYOFBS/?utm_source=ig_embed&utm_campaign=loading
      login
      graphql_object = get_content_of_subpage_from_url(
        "https://www.instagram.com/p/#{id}/",
        "/graphql",
        "data,xdt_api__v1__media__shortcode__web_info,items"
      )

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
          video = graphql_object["video"].first["contentUrl"]
          video_preview_image = graphql_object["video"].first["thumbnailUrl"]
        end
      else
        # We need to see if this is a single image post or a slideshow. We do that
        # by looking for a single image, if it's not there, we assume the alternative.
        graphql_object = graphql_object["data"]["xdt_api__v1__media__shortcode__web_info"]


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
      end

      screenshot_file = take_screenshot()

      # This has to run last since it switches pages
      user = User.lookup([username]).first
      page.quit

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
      begin
        find_button("See Post").click
        sleep(0.1)
      rescue Capybara::ElementNotFound
        # Do nothing if the element is not found
      end

      # Take the screenshot and return it
      save_screenshot("#{Zorki.temp_storage_location}/instagram_screenshot_#{SecureRandom.uuid}.png")
    end
  end
end
