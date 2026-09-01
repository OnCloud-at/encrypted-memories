#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "release_contract"

class GitHubReleaseContractTest < Minitest::Test
  def payload(tag: "v1.2.0", prerelease: false, body: valid_body)
    {
      "id" => 241_000_123,
      "tag_name" => tag,
      "draft" => false,
      "prerelease" => prerelease,
      "published_at" => "2026-09-01T10:00:00Z",
      "body" => body
    }
  end

  def valid_body
    <<~MARKDOWN
      Notes for GitHub readers stay outside the Apple sections.

      ## Deutsch
      Neue gemeinsame Mediathek.

      ## English
      New shared library.

      ## Contributors
      Thanks to an external contributor.
    MARKDOWN
  end

  def test_stable_release_routes_to_app_store
    release = GitHubReleaseContract.parse(payload)

    assert_equal "1.2.0", release.version
    assert_equal "241000123", release.build_number
    assert_equal "app-store", release.channel
    assert_equal "Neue gemeinsame Mediathek.", release.notes.fetch("de-DE")
    assert_equal "New shared library.", release.notes.fetch("en-US")
    refute_includes release.notes.values.join, "contributor"
  end

  def test_beta_and_release_candidate_route_to_internal_testflight
    %w[v1.2.0-beta.1 v1.2.0-rc.3].each do |tag|
      release = GitHubReleaseContract.parse(payload(tag: tag, prerelease: true))

      assert_equal "1.2.0", release.version
      assert_equal "testflight", release.channel
    end
  end

  def test_prerelease_flag_must_match_the_tag
    error = assert_raises(GitHubReleaseContract::Error) do
      GitHubReleaseContract.parse(payload(tag: "v1.2.0-beta.1", prerelease: false))
    end

    assert_match(/prerelease flag/, error.message)
  end

  def test_release_requires_both_apple_note_sections
    error = assert_raises(GitHubReleaseContract::Error) do
      GitHubReleaseContract.parse(payload(body: "## English\nOnly English."))
    end

    assert_match(/Deutsch/, error.message)
  end

  def test_release_rejects_duplicate_apple_note_sections
    error = assert_raises(GitHubReleaseContract::Error) do
      GitHubReleaseContract.parse(payload(body: "## Deutsch\nA\n## Deutsch\nB\n## English\nC"))
    end

    assert_match(/duplicate sections/, error.message)
  end

  def test_release_accepts_windows_line_endings_and_repeated_unrelated_sections
    body = valid_body + "\n## Fixed\nOne\n## Fixed\nTwo\n"
    release = GitHubReleaseContract.parse(payload(body: body.gsub("\n", "\r\n")))

    assert_equal "Neue gemeinsame Mediathek.", release.notes.fetch("de-DE")
  end

  def test_release_rejects_draft_or_unpublished_payload
    error = assert_raises(GitHubReleaseContract::Error) do
      GitHubReleaseContract.parse(payload.merge("draft" => true))
    end

    assert_match(/must be published/, error.message)
  end

  def test_write_creates_only_localized_apple_notes
    Dir.mktmpdir do |directory|
      output = File.join(directory, "output")
      notes = File.join(directory, "notes")
      release = GitHubReleaseContract.parse(payload)

      GitHubReleaseContract.write(release, directory: notes, output_path: output, summary_path: nil)

      assert_equal "Neue gemeinsame Mediathek.\n", File.read(File.join(notes, "de-DE.txt"))
      assert_equal "New shared library.\n", File.read(File.join(notes, "en-US.txt"))
      assert_includes File.read(output), "channel=app-store\n"
      assert_includes File.read(output), "notes_de_base64=TmV1ZSBnZW1laW5zYW1lIE1lZGlhdGhlay4=\n"
    end
  end
end
