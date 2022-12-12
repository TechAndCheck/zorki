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
      graphql_object = get_content_of_subpage_from_url("https://www.instagram.com/p/#{id}/", "/info")

      # We need to see if this is a single image post or a slideshow. We do that
      # by looking for a single image, if it's not there, we assume the alternative.
      unless graphql_object["items"][0].has_key?("video_versions")
        # Check if there is a slideshow or not
        unless graphql_object["items"][0].has_key?("carousel_media")
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
        username = graphql_object["items"][0]["caption"]["user"]["username"]
      else
        text = ""
        username = graphql_object["items"][0]["user"]["username"]
      end

      date = DateTime.strptime(graphql_object["items"][0]["taken_at"].to_s, "%s")
      number_of_likes = graphql_object["items"][0]["like_count"]

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
