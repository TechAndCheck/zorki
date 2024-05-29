require "logger"
require "selenium-webdriver"

# Design taken from https://blog.appsignal.com/2021/08/24/responsible-monkeypatching-in-ruby.html

module SeleniumMonkeypatch
  class << self
    @@logger = Logger.new(STDOUT)
    @@logger.level = Logger::INFO

    def apply_patch
      target_class = find_class
      target_method = find_method(target_class)

      unless target_method
        raise "Could not find class or method when patching Selenium::WebDriver::DevTools.send_cmd"
      end

      @@logger.info "#{__FILE__} is monkeypatching Selenium::WebDriver::DevTools.send_cmd"
      target_class.prepend(InstanceMethods)
    end

    private

      def find_class
        Kernel.const_get("Selenium::WebDriver::DevTools")
      rescue NameError
      end

      def find_method(class_)
        return unless class_
        class_.instance_method(:send_cmd)
      rescue NameError
      end
  end

  module InstanceMethods
    # We're monkeypatching the following method so that Selenium doesn't raise errors when we fail to call `continue` on requests
    def send_cmd(method, **params)
      data = { method: method, params: params.compact }
      data[:sessionId] = @session_id if @session_id
      message = @ws.send_cmd(**data)
      if message.nil? == false && message["error"] && (method != "Fetch.continueRequest")
        raise Selenium::WebDriver::Error::WebDriverError, error_message(message["error"])
      end

      message
    end
  end
end

SeleniumMonkeypatch.apply_patch
