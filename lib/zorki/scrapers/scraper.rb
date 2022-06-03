# frozen_string_literal: true

# require_relative "user_scraper"
require "capybara/dsl"
require "dotenv/load"
require "oj"
require "selenium-webdriver"
require "logger"
require "debug"

Capybara.register_driver :chrome do |app|
  client = Selenium::WebDriver::Remote::Http::Default.new
  client.read_timeout = 10  # Don't wait 60 seconds to return Net::ReadTimeoutError. We'll retry through Hypatia after 10 seconds
  Capybara::Selenium::Driver.new(app, browser: :chrome, http_client: client)
end

Capybara.default_driver = :selenium_chrome
Capybara.default_max_wait_time = 15
Capybara.threadsafe = true
Capybara.reuse_server = true
Capybara.app_host = "https://instagram.com"

module Zorki
  class Scraper
    include Capybara::DSL

    @@logger = Logger.new(STDOUT)
    @@logger.level = Logger::WARN

    def initialize
      Capybara.default_driver = :selenium_chrome
      Capybara.app_host = "https://instagram.com"
    end

    # Instagram uses GraphQL (like most of Facebook I think), and returns an object that actually
    # is used to seed the page. We can just parse this for most things.
    #
    # @returns Hash a ruby hash of the JSON data
    def get_content_of_subpage_from_url(url, subpage_search)
      # Our user data no longer lives in the graphql object passed initially with the page.
      # Instead it comes in as part of a subsequent call. This intercepts all calls, checks if it's
      # the one we want, and then moves on.
      response_body = nil

      page.driver.browser.intercept do |request, &continue|
        # This passes the request forward unmodified, since we only care about the response
        continue.call(request) do |response|
          # Check if 1. it's the call we're looking for, and 2. not a CORS prefetch
          if request.url.include?(subpage_search) && response.body.present?
            # Setting this will finish up the loop we start below
            response_body = response.body

            # Remove this callback so other requests don't go through the same thing
            page.driver.browser.devtools.callbacks["Fetch.requestPaused"] = []
          end
        end
      end

      # Now that the intercept is set up, we visit the page we want
      visit(url)

      # We wait until the correct intercept is processed or we've waited 60 seconds
      count = 0
      while response_body.nil? || count > 60
        sleep(1)
        count += 1
      end

      Oj.load(response_body)
    end

  private

    def login
      # We don't have to login if we already are
      begin
        return if find_field("Search").present?
      rescue Capybara::ElementNotFound; end

      # Go to the home page
      visit("https://instagram.com")
      # Check if we're redirected to a login page, if we aren't we're already logged in
      return unless page.has_xpath?('//*[@id="loginForm"]/div/div[3]/button')

      sleep(rand * 10)

      loop_count = 0
      while loop_count < 5 do
        fill_in("username", with: ENV["INSTAGRAM_USER_NAME"])
        sleep(rand * 10)
        fill_in("password", with: ENV["INSTAGRAM_PASSWORD"])
        click_on("Log In")

        break unless has_css?('p[data-testid="login-error-message"')
        loop_count += 1
        @@logger.debug("Error logging into Instagram, trying again")
        sleep(rand * 30.4)
      end

      # Sometimes Instagram just... doesn't let you log in
      raise "Instagram not accessible" if loop_count == 5

      # No we don't want to save our login credentials
      click_on("Not Now")
    end

    def fetch_image(url)
      request = Typhoeus::Request.new(url, followlocation: true)
      request.on_complete do |response|
        if request.success?
          return request.body
        elsif request.timed_out?
          raise Zorki::Error("Fetching image at #{url} timed out")
        else
          raise Zorki::Error("Fetching image at #{url} returned non-successful HTTP server response #{request.code}")
        end
      end
    end

    # Convert a string to an integer
    def number_string_to_integer(number_string)
      # First we have to remove any commas in the number or else it all breaks
      number_string = number_string.delete(",")
      # Is the last digit not a number? If so, we're going to have to multiply it by some multiplier
      should_expand = /[0-9]/.match(number_string[-1, 1]).nil?

      # Get the last index and remove the letter at the end if we should expand
      last_index = should_expand ? number_string.length - 1 : number_string.length
      number = number_string[0, last_index].to_f
      multiplier = 1
      # Determine the multiplier depending on the letter indicated
      case number_string[-1, 1]
      when "m"
        multiplier = 1_000_000
      end

      # Multiply everything and insure we get an integer back
      (number * multiplier).to_i
    end
  end
end

require_relative "post_scraper"
require_relative "user_scraper"
