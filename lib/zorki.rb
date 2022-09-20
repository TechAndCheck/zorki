# frozen_string_literal: true

require_relative "zorki/version"
require_relative "zorki/monkeypatch"

# Representative objects we create
require_relative "zorki/user"
require_relative "zorki/post"

require "helpers/configuration"
require_relative "zorki/scrapers/scraper"

module Zorki
  extend Configuration

  class Error < StandardError
    def initialize(msg = "Zorki encountered an error scraping Instagram")
      super
    end
  end

  class ContentUnavailableError < Error
    def initialize(msg = "Zorki could not find content requested")
      super
    end
  end

  class RetryableError < Error; end

  class ImageRequestTimedOutError < RetryableError
    def initialize(msg = "Zorki encountered a timeout error requesting an image")
      super
    end
  end

  class ImageRequestFailedError < RetryableError
    def initialize(msg = "Zorki received a non-200 response requesting an image")
      super
    end
  end

  define_setting :temp_storage_location, "tmp/zorki"

  # Extract the file extension from a media URL
  # E.g. ".png" from https://scontent-atl3-2.xx.fbcdn.net/v/t39.30808-1.png?stp=dst-png_p148x148
  def self.extract_file_extension_from_url(url)
    extension = url.split(".").last

    # Do some basic checks so we just empty out if there's something weird in the file extension
    # that could do some harm.
    extension = nil unless /^[a-zA-Z0-9]+$/.match?(extension)
    extension = ".#{extension}" unless extension.nil?
    extension
  end

  # Get an image from a URL and save to a temp folder set in the configuration under
  # temp_storage_location
  def self.retrieve_media(url)
    response = Typhoeus.get(url)

    extension = Zorki.extract_file_extension_from_url(url)
    temp_file_name = "#{Zorki.temp_storage_location}/#{SecureRandom.uuid}#{extension}"

    # We do this in case the folder isn't created yet, since it's a temp folder we'll just do so
    self.create_temp_storage_location
    File.binwrite(temp_file_name, response.body)
    temp_file_name
  end

private

  def self.create_temp_storage_location
    return if File.exist?(Zorki.temp_storage_location) && File.directory?(Zorki.temp_storage_location)
    FileUtils.mkdir_p Zorki.temp_storage_location
  end
end
