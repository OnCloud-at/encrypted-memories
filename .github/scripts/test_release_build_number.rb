#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "release_build_number"

class AppleReleaseBuildNumberTest < Minitest::Test
  def command_for_history
    lambda do |*arguments|
      assert_equal ["git", "rev-list", "--first-parent", "a" * 40], arguments
      ["#{'a' * 40}\n#{AppleReleaseBuildNumber::BASELINE_COMMIT}\n", Struct.new(:success?).new(true)]
    end
  end

  def test_published_legacy_release_keeps_its_uploaded_number
    build = AppleReleaseBuildNumber.for_release(
      "a" * 40, { "id" => AppleReleaseBuildNumber::LAST_COMMIT_NUMBERED_RELEASE_ID },
      command: command_for_history
    )

    assert_equal "382818669", build
  end

  def test_distinct_releases_of_the_same_commit_get_distinct_builds
    first_id = AppleReleaseBuildNumber::LAST_COMMIT_NUMBERED_RELEASE_ID + 1
    first = AppleReleaseBuildNumber.for_release("a" * 40, { "id" => first_id }, command: command_for_history)
    second = AppleReleaseBuildNumber.for_release("a" * 40, { "id" => first_id + 1 }, command: command_for_history)
    retry_build = AppleReleaseBuildNumber.for_release("a" * 40, { "id" => first_id }, command: command_for_history)

    assert_equal first_id.to_s, first
    assert_equal (first_id + 1).to_s, second
    assert_equal first, retry_build
  end

  def test_invalid_release_ids_are_rejected_before_git
    [nil, 0, -1, "383102209", 383102209.5].each do |id|
      assert_raises(AppleReleaseBuildNumber::Error) do
        AppleReleaseBuildNumber.for_release("a" * 40, { "id" => id }, command: ->(*) { flunk "must not run git" })
      end
    end
  end

  def test_baseline_commit_keeps_the_first_uploaded_build_number
    build = AppleReleaseBuildNumber.from_first_parent_history([
      AppleReleaseBuildNumber::BASELINE_COMMIT
    ])

    assert_equal "382818668", build
  end

  def test_each_later_first_parent_commit_increments_once
    build = AppleReleaseBuildNumber.from_first_parent_history([
      "b" * 40,
      "a" * 40,
      AppleReleaseBuildNumber::BASELINE_COMMIT
    ])

    assert_equal "382818670", build
  end

  def test_rejects_a_commit_outside_the_anchored_main_history
    error = assert_raises(AppleReleaseBuildNumber::Error) do
      AppleReleaseBuildNumber.from_first_parent_history(["a" * 40])
    end

    assert_match(/first-parent main history/, error.message)
  end

  def test_write_exports_one_shared_platform_build_number
    Dir.mktmpdir do |directory|
      output = File.join(directory, "output")
      summary = File.join(directory, "summary")

      AppleReleaseBuildNumber.write("382818669", output_path: output, summary_path: summary)

      assert_equal "build_number=382818669\n", File.read(output)
      assert_equal "- Apple build: 382818669\n", File.read(summary)
    end
  end
end
