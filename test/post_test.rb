# frozen_string_literal: true

require "test_helper"

class PostTest < Minitest::Test
  # i_suck_and_my_tests_are_order_dependent!()

  def teardown
    cleanup_temp_folder
  end

  # Note: if this fails, check the account, the number may just have changed
  # We're using Pete Souza because Obama's former photographer isn't likely to be taken down
  def test_a_single_image_post_returns_properly_when_scraped
    post = Zorki::Post.lookup(["COOCAfCFpkP"]).first
    assert_equal 1, post.image_file_names.count
  end

  def test_a_slideshow_post_returns_properly_when_scraped
    post = Zorki::Post.lookup(["CNJJM2elXQ0"]).first
    assert_equal 3, post.image_file_names.count
    assert post.text.start_with? "Opening Day 2010"
    assert_equal DateTime.parse("Apr 2, 2021").to_date, post.date.to_date
    assert post.number_of_likes > 1
    assert post.user.is_a?(Zorki::User)
    assert_equal "petesouza", post.user.username
    assert_equal "CNJJM2elXQ0", post.id
    assert_nil post.video_file_name
    assert_nil post.video_preview_image
    assert_not_nil post.screenshot_file
  end

  def test_a_post_marked_as_misinfo_works_still
    post = Zorki::Post.lookup(["CBZkDi1nAty"]).first
    assert_equal 1, post.image_file_names.count
  end

  def test_another_post_works
    post = Zorki::Post.lookup(["CmTc591tu0n"]).first
    assert_not_nil post.image_file_names
    assert_not_nil post.user
  end

  def test_a_video_post_returns_properly_when_scraped
    post = Zorki::Post.lookup(["Cak2RfYhqvE"]).first
    assert_not_nil post.video_file_name
    assert_not_nil post.video_preview_image
    assert_not_nil post.screenshot_file
    assert_not_nil post.user
  end

  def test_a_reel_post_returns_properly_when_scraped
    post = Zorki::Post.lookup(["DAZC1_rMRfR"]).first
    assert_not_nil post.video_file_name
    assert_not_nil post.video_preview_image
    assert_not_nil post.screenshot_file
    assert_not_nil post.user

    assert post.video_file_name.end_with?(".mp4")
    assert post.video_preview_image.end_with?(".jpg")
  end

  def test_a_video_post_properly_downloads_video
    post = Zorki::Post.lookup(["Cak2RfYhqvE"]).first
    assert !post.video_file_name.start_with?("https://")
    assert File.exist?(post.video_file_name)
    assert post.video_file_name.end_with?(".mp4")
    assert_not_nil post.user
  end

  def test_a_post_has_been_removed
    assert_raises Zorki::ContentUnavailableError do
      Zorki::Post.lookup(["sfhslsfjdls"])
    end
  end

  def test_a_post_still_works
    post = Zorki::Post.lookup(["C5BV8kuMJm4"]).first
    assert_not_nil post.image_file_names
    assert_not_nil post.screenshot_file
    assert_not_nil post.user
  end

  def test_running_two_scrapes_works # Seriously, this is breaking, not sure why
    post = Zorki::Post.lookup(["Cak2RfYhqvE"]).first
    assert_not_nil post.video_file_name
    post = Zorki::Post.lookup(["Cak2RfYhqvE"]).first
    assert_not_nil post.video_file_name
    assert_not_nil post.user
  end

  def test_another_link
    post = Zorki::Post.lookup(["C1p3LKJxfch"]).first
    assert_not_nil post.image_file_names
    assert_not_nil post.user
  end

  def test_another_video
    post = Zorki::Post.lookup(["DBKb3qdMEwm"]).first
    assert_not_nil post.video_file_name
    assert_not_nil post.video_preview_image
    assert_not_nil post.screenshot_file
    assert_not_nil post.user

    assert post.video_file_name.end_with?(".mp4")
    assert post.video_preview_image.end_with?(".jpg")
  end

  def test_another_video_2
    post = Zorki::Post.lookup(["DGhXRPpTCwy"]).first
    assert_not_nil post.video_file_name
    assert_not_nil post.video_preview_image
    assert_not_nil post.screenshot_file
    assert_not_nil post.user

    assert post.video_file_name.end_with?(".mp4")
    assert post.video_preview_image.end_with?(".jpg")
  end

  def test_a_video_post_properly_downloads_video_2
    post = Zorki::Post.lookup(["DGSMxWYPvvN"]).first
    assert !post.video_file_name.start_with?("https://")
    assert File.exist?(post.video_file_name)
    assert post.video_file_name.end_with?(".mp4")
    assert_not_nil post.user
  end
end
