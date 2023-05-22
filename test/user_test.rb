# frozen_string_literal: true

require "test_helper"

class UserTest < Minitest::Test
  # Note: if this fails, check the account, the number may just have changed
  # We're using Pete Souza because Obama's former photographer isn't likely to be taken down
  def test_a_username_returns_properly_when_scraped
    user = Zorki::User.lookup(["therock"]).first
    assert_equal user.name, "Dwayne Johnson"
    assert_equal user.username, "therock"
    assert user.number_of_posts > 1000
    assert user.number_of_followers > 1000000
    # broken for the moment
    # assert user.number_of_following > 100
    # assert user.verified
    assert user.profile_link, "linktr.ee/therock"
    assert !user.profile.empty?
    assert !user.profile_image.nil?
  end
end
