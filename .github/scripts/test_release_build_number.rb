#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "release_build_number"

class AppleReleaseBuildNumberTest < Minitest::Test
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
