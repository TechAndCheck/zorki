# frozen_string_literal: true

require "test_helper"

class UserTest < Minitest::Test
  # Note: if this fails, check the account, the number may just have changed
  # We're using Pete Souza because Obama's former photographer isn't likely to be taken down
  def test_a_username_returns_properly_when_scraped
    user = Zorki::User.lookup(["therock"]).first
    assert_equal "Dwayne Johnson", user.name
    assert_equal "therock", user.username
    assert user.number_of_posts > 1000
    assert user.number_of_followers > 1000000
    assert user.number_of_following > -1
    assert user.verified
    assert user.profile_link, "http://therock.komi.io"
    assert !user.profile.nil?
    assert !user.profile_image.nil?
  end

  def test_another
    Zorki::User.lookup(["markushasaya"]).first
  end

  def test_another_2
    Zorki::User.lookup(["chefaz"]).first
  end

  def test_another_3
    Zorki::User.lookup(["theonion"]).first
  end
end
