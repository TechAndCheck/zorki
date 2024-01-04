# frozen_string_literal: true

require "test_helper"

class ZorkiTest < Minitest::Test
  # def test_that_it_has_a_version_number
  #   assert_not_nil ::Zorki::VERSION
  # end

  def test_that_additional_data_can_be_added_to_content_unavailable_error
    error = Zorki::ContentUnavailableError.new("this is a message", additional_data: { some: "stuff" })
    assert_not_nil error.additional_data
    assert error.additional_data.key?(:some)
    assert_equal "stuff", error.additional_data[:some]

    assert_not_nil error.to_honeybadger_context
    assert error.to_honeybadger_context.key?(:some)
    assert_equal "stuff", error.to_honeybadger_context[:some]
  end
end
