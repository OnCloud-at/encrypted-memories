#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "json"

module AppleReleaseBuildNumber
  # v1.0.2-beta.1 was the first build uploaded by this release pipeline. Its GitHub release ID
  # became CFBundleVersion 382818668. macOS build numbers cannot move backwards, so that exact
  # source commit anchors the already-published releases. Keep their mapping for retries and external
  # distribution. New releases use their immutable GitHub ID: separate beta/stable releases build new
  # binaries even on the same commit, while retrying one release remains idempotent.
  BASELINE_COMMIT = "68c8f3f7de98ce4b3385f655d97252d40dd2378e"
  BASELINE_BUILD_NUMBER = 382_818_668
  LAST_COMMIT_NUMBERED_RELEASE_ID = 383_102_208 # v1.0.2-beta.3

  class Error < StandardError; end

  module_function

  def from_first_parent_history(history)
    normalized = history.map(&:strip).reject(&:empty?)
    distance = normalized.index(BASELINE_COMMIT)
    unless distance
      raise Error, "Release commit is not on the supported first-parent main history"
    end

    (BASELINE_BUILD_NUMBER + distance).to_s
  end

  def resolve(commit, command: Open3.method(:capture2e))
    unless /\A[0-9a-f]{40}\z/.match?(commit)
      raise Error, "Release commit must be a full lowercase Git SHA"
    end

    output, status = command.call("git", "rev-list", "--first-parent", commit)
    raise Error, "Could not inspect the release commit history" unless status.success?

    from_first_parent_history(output.lines)
  end

  def for_release(commit, payload, command: Open3.method(:capture2e))
    release_id = payload.fetch("id")
    unless release_id.is_a?(Integer) && release_id.positive?
      raise Error, "GitHub release ID must be a positive integer"
    end

    # Validate source ancestry for both numbering schemes, including re-runs of old releases.
    legacy_build = resolve(commit, command: command)
    return legacy_build if release_id <= LAST_COMMIT_NUMBERED_RELEASE_ID

    release_id.to_s
  rescue KeyError
    raise Error, "GitHub release payload is missing its ID"
  end

  def write(build_number, output_path: ENV["GITHUB_OUTPUT"], summary_path: ENV["GITHUB_STEP_SUMMARY"])
    if output_path && !output_path.empty?
      File.open(output_path, "a") { |output| output.puts("build_number=#{build_number}") }
    end
    return unless summary_path && !summary_path.empty?

    File.open(summary_path, "a") { |summary| summary.puts("- Apple build: #{build_number}") }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    commit = ARGV.fetch(0)
    payload = JSON.parse(File.read(ARGV.fetch(1)))
    build_number = AppleReleaseBuildNumber.for_release(commit, payload)
    AppleReleaseBuildNumber.write(build_number)
    puts "Resolved Apple build #{build_number} for #{commit}."
  rescue AppleReleaseBuildNumber::Error, IndexError, JSON::ParserError => error
    warn "Invalid Apple release commit: #{error.message}"
    exit 1
  end
end
