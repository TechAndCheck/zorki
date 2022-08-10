# frozen_string_literal: true

require "capybara/dsl"
require "dotenv/load"
require "oj"
require "selenium-webdriver"
require "logger"
require "debug"

# 2022-06-07 14:15:23 WARN Selenium [DEPRECATION] [:browser_options] :options as a parameter for driver initialization is deprecated. Use :capabilities with an Array of value capabilities/options if necessary instead.

options = Selenium::WebDriver::Chrome::Options.new
options.add_argument("--window-size=1400,1400")
options.add_argument("--no-sandbox")
options.add_argument("--disable-dev-shm-usage")
options.add_argument("--user-data-dir=/tmp/tarun")

Capybara.register_driver :chrome_zorki do |app|
  client = Selenium::WebDriver::Remote::Http::Default.new
  client.read_timeout = 60  # Don't wait 60 seconds to return Net::ReadTimeoutError. We'll retry through Hypatia after 10 seconds
  Capybara::Selenium::Driver.new(app, browser: :chrome, url: "http://localhost:4444/wd/hub", capabilities: options, http_client: client)
end

Capybara.threadsafe = true
Capybara.default_max_wait_time = 15
Capybara.reuse_server = true

module Zorki
  class Scraper
    include Capybara::DSL

    @@logger = Logger.new(STDOUT)
    @@logger.level = Logger::DEBUG
    @@logger.datetime_format = "%Y-%m-%d %H:%M:%S"
    @@session_id = nil

    def initialize
      Capybara.current_driver = :chrome_zorki
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

      @@logger.debug "Ready to intercept requests"
      page.driver.browser.intercept do |request, &continue|
        # This passes the request forward unmodified, since we only care about the response
        continue.call(request) && next unless request.url.include?(subpage_search)

        continue.call(request) do |response|
          # Check if not a CORS prefetch and finish up if not
          response_body = response.body if response.body.present?
        end
      rescue Selenium::WebDriver::Error::WebDriverError
        @@logger.debug "(INFO) Error receiving #{request.url}"
        # Eat them
      end

      @@logger.debug "#{subpage_search} request intercepted. About to visit URL #{url}"
      # Now that the intercept is set up, we visit the page we want
      visit(url)
      # We wait until the correct intercept is processed or we've waited 60 seconds
      # count = 0
      start_time = Time.now
      while response_body.nil? && (Time.now - start_time) < 60
        sleep(0.1)
      end

      # Remove this callback so other requests don't go through the same thing
      page.driver.browser.devtools.callbacks["Fetch.requestPaused"] = []

      raise ContentUnavailableError if response_body.nil?

      Oj.load(response_body)
    end

  private

    def login
      # Reset the sessions so that there's nothing laying around
      page.quit

      # Check if we're on a Instagram page already, if not visit it.
      visit ("https://instagram.com") unless page.driver.browser.current_url.include? "instagram.com"

      # We don't have to login if we already are
      @@logger.debug "Checking if we're on instagram. Max wait 10s"
      begin
        return if find_field("Search", wait: 10).present?
      rescue Capybara::ElementNotFound; end

      @@logger.debug "Visiting instagram :)"
      # Go to the home page
      visit("https://instagram.com")
      # Check if we're redirected to a login page, if we aren't we're already logged in

      @@logger.debug "Checking for login xpath. Max wait 10s"
      return unless page.has_xpath?('//*[@id="loginForm"]/div/div[3]/button', wait: 10)

      loop_count = 0
      while loop_count < 5 do
        fill_in("username", with: ENV["INSTAGRAM_USER_NAME"])
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
