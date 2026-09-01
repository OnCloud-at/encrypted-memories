#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "base64"
require "json"

module GitHubReleaseContract
  MAX_APPLE_RELEASE_NOTES_LENGTH = 4_000
  TAG_PATTERN = /\Av(?<version>[0-9]+\.[0-9]+\.[0-9]+)(?:-(?<channel>beta|rc)\.(?<sequence>[1-9][0-9]*))?\z/
  LOCALES = {
    "de-DE" => "Deutsch",
    "en-US" => "English"
  }.freeze

  class Error < StandardError; end

  Release = Data.define(:tag, :version, :build_number, :prerelease, :channel, :notes)

  module_function

  def parse(payload)
    release_id = Integer(payload.fetch("id"), exception: false)
    unless release_id&.positive? && release_id.to_s.length <= 18
      raise Error, "GitHub release ID must be a positive integer with at most 18 digits"
    end
    raise Error, "GitHub release must be published" if payload["draft"] == true || payload["published_at"].to_s.empty?

    tag = payload.fetch("tag_name").to_s
    match = TAG_PATTERN.match(tag)
    raise Error, "Tag must use vMAJOR.MINOR.PATCH, optionally followed by -beta.N or -rc.N" unless match

    prerelease = payload.fetch("prerelease")
    raise Error, "GitHub prerelease must be true or false" unless [true, false].include?(prerelease)

    expected_prerelease = !match[:channel].nil?
    if prerelease != expected_prerelease
      raise Error, "GitHub prerelease flag does not match tag #{tag}"
    end

    notes = extract_notes(payload.fetch("body", ""))
    Release.new(
      tag: tag,
      version: match[:version],
      build_number: release_id.to_s,
      prerelease: prerelease,
      channel: prerelease ? "testflight" : "app-store",
      notes: notes
    )
  rescue KeyError => error
    raise Error, "GitHub release payload is missing #{error.key}"
  end

  def extract_notes(body)
    normalized_body = body.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
    headings = normalized_body.scan(/^##[ \t]+(.+?)[ \t]*$/).flatten
    duplicates = headings.tally.select do |heading, count|
      LOCALES.value?(heading) && count > 1
    end.keys
    raise Error, "Release notes contain duplicate sections: #{duplicates.join(', ')}" unless duplicates.empty?

    LOCALES.to_h do |locale, heading|
      text = normalized_body[/^##[ \t]+#{Regexp.escape(heading)}[ \t]*$\n(?<text>.*?)(?=^##[ \t]+|\z)/m, :text]
      text = text.to_s.strip
      raise Error, "Release notes are missing the ## #{heading} section" if text.empty?
      if text.length > MAX_APPLE_RELEASE_NOTES_LENGTH
        raise Error, "## #{heading} exceeds #{MAX_APPLE_RELEASE_NOTES_LENGTH} characters"
      end

      [locale, text]
    end
  end

  def write(release, directory:, output_path: ENV["GITHUB_OUTPUT"], summary_path: ENV["GITHUB_STEP_SUMMARY"])
    FileUtils.mkdir_p(directory)
    release.notes.each do |locale, text|
      File.write(File.join(directory, "#{locale}.txt"), "#{text}\n", encoding: "UTF-8")
    end

    if output_path && !output_path.empty?
      File.open(output_path, "a") do |output|
        output.puts("tag=#{release.tag}")
        output.puts("version=#{release.version}")
        output.puts("build_number=#{release.build_number}")
        output.puts("prerelease=#{release.prerelease}")
        output.puts("channel=#{release.channel}")
        output.puts("notes_de_base64=#{Base64.strict_encode64(release.notes.fetch('de-DE'))}")
        output.puts("notes_en_base64=#{Base64.strict_encode64(release.notes.fetch('en-US'))}")
      end
    end

    return unless summary_path && !summary_path.empty?

    File.open(summary_path, "a") do |summary|
      summary.puts("## Apple release")
      summary.puts
      summary.puts("- Tag: #{release.tag}")
      summary.puts("- App version: #{release.version}")
      summary.puts("- Build: #{release.build_number}")
      summary.puts("- Destination: #{release.prerelease ? 'internal TestFlight' : 'App Store review'}")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    payload_path, notes_directory = ARGV
    raise GitHubReleaseContract::Error, "Usage: release_contract.rb RELEASE_JSON NOTES_DIRECTORY" unless
      payload_path && notes_directory

    payload = JSON.parse(File.read(payload_path, encoding: "UTF-8"))
    release = GitHubReleaseContract.parse(payload)
    GitHubReleaseContract.write(release, directory: notes_directory)
  rescue GitHubReleaseContract::Error, JSON::ParserError, Errno::ENOENT => error
    warn "Invalid GitHub release: #{error.message}"
    exit 1
  end
end
