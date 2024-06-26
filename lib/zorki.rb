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
    attr_reader :additional_data

    def initialize(msg = "Zorki could not find content requested", additional_data: {})
      super(msg)
      @additional_data = additional_data
    end

    def to_honeybadger_context
      @additional_data
    end
  end

  class UserScrapingError < Error
    def initialize(msg = "Zorki encountered an error scraping a user", additional_data: {})
      super(msg)
      @additional_data = additional_data
    end

    def to_honeybadger_context
      @additional_data
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

  class ImageRequestZeroSize < RetryableError; end

  define_setting :temp_storage_location, "tmp/zorki"

  # Get an image from a URL and save to a temp folder set in the configuration under
  # temp_storage_location

  # We do this because sometimes the images are coming back sized zero
  def self.retrieve_media(url)
    count = 0

    until count == 5
      temp_file_name = attempt_retrieve_media(url)

      # If it's more than 1kb return properly
      return temp_file_name if File.size(temp_file_name) > 100

      # Delete the file since we want to retry
      File.delete(temp_file_name)
      count += 1
    end

    raise(ImageRequestZeroSize)
  end

  def self.attempt_retrieve_media(url)
    response = Typhoeus.get(url)

    # Get the file extension if it's in the file
    stripped_url = url.split("?").first  # remove URL query params
    extension = stripped_url.split(".").last

    # Do some basic checks so we just empty out if there's something weird in the file extension
    # that could do some harm.
    if extension.length.positive?
      extension = nil unless /^[a-zA-Z0-9]+$/.match?(extension)
      extension = ".#{extension}" unless extension.nil?
    end

    temp_file_name = "#{Zorki.temp_storage_location}/instagram_media_#{SecureRandom.uuid}#{extension}"

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
