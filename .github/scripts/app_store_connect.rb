#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "uri"

module AppStoreConnect
  API_ROOT = "https://api.appstoreconnect.apple.com"
  PLATFORMS = %w[IOS MAC_OS].freeze
  REVIEWED_BUILD_STATES = %w[WAITING_FOR_REVIEW IN_REVIEW APPROVED].freeze
  SUBMITTED_VERSION_STATES = %w[
    WAITING_FOR_REVIEW IN_REVIEW PENDING_DEVELOPER_RELEASE PENDING_APPLE_RELEASE
    PROCESSING_FOR_DISTRIBUTION READY_FOR_DISTRIBUTION READY_FOR_SALE
  ].freeze

  class Error < StandardError; end
  class TransportError < Error; end

  module_function

  def base64url(value)
    Base64.urlsafe_encode64(value, padding: false)
  end

  def fixed_width_integer(value)
    hex = value.to_i.to_s(16)
    hex = "0#{hex}" if hex.length.odd?
    bytes = [hex].pack("H*")
    raise Error, "Invalid ES256 signature" if bytes.bytesize > 32

    ("\0" * (32 - bytes.bytesize)) + bytes
  end

  def jwt(issuer_id:, key_id:, private_key:, now: Time.now.to_i)
    header = base64url(JSON.generate(alg: "ES256", kid: key_id, typ: "JWT"))
    claims = base64url(JSON.generate(iss: issuer_id, iat: now, exp: now + 1_200, aud: "appstoreconnect-v1"))
    signing_input = "#{header}.#{claims}"
    key = OpenSSL::PKey.read(private_key)
    components = OpenSSL::ASN1.decode(key.sign(OpenSSL::Digest.new("SHA256"), signing_input)).value
    raise Error, "Invalid ES256 signature" unless components.length == 2

    signature = components.map { |component| fixed_width_integer(component.value) }.join
    "#{signing_input}.#{base64url(signature)}"
  end

  def build_filters(app_id:, version:, build_number:, platform:)
    {
      "filter[app]" => app_id,
      "filter[version]" => build_number,
      "filter[preReleaseVersion.version]" => version,
      "filter[preReleaseVersion.platform]" => platform,
      "filter[buildAudienceType]" => "APP_STORE_ELIGIBLE",
      "limit" => "10"
    }
  end

  def beta_group_payload(app_id:, name:, internal:)
    {
      data: {
        type: "betaGroups",
        attributes: {
          name: name,
          isInternalGroup: internal,
          feedbackEnabled: true,
          hasAccessToAllBuilds: false
        },
        relationships: {
          app: { data: { type: "apps", id: app_id } }
        }
      }
    }
  end

  def beta_group_builds_payload(build_ids)
    { data: build_ids.map { |id| { type: "builds", id: id } } }
  end

  def beta_review_payload(build_id)
    {
      data: {
        type: "betaAppReviewSubmissions",
        relationships: { build: { data: { type: "builds", id: build_id } } }
      }
    }
  end

  def app_store_build_payload(build_id)
    { data: { type: "builds", id: build_id } }
  end

  def release_request_payload(version_id)
    {
      data: {
        type: "appStoreVersionReleaseRequests",
        relationships: {
          appStoreVersion: { data: { type: "appStoreVersions", id: version_id } }
        }
      }
    }
  end

  def review_submission_payload(app_id:, platform:)
    {
      data: {
        type: "reviewSubmissions",
        attributes: { platform: platform },
        relationships: { app: { data: { type: "apps", id: app_id } } }
      }
    }
  end

  def review_item_payload(submission_id:, version_id:)
    {
      data: {
        type: "reviewSubmissionItems",
        relationships: {
          reviewSubmission: { data: { type: "reviewSubmissions", id: submission_id } },
          appStoreVersion: { data: { type: "appStoreVersions", id: version_id } }
        }
      }
    }
  end

  def submit_review_payload(submission_id)
    {
      data: {
        type: "reviewSubmissions",
        id: submission_id,
        attributes: { submitted: true }
      }
    }
  end

  class Client
    def initialize(issuer_id:, key_id:, private_key:, sleeper: ->(seconds) { sleep(seconds) })
      @issuer_id = issuer_id
      @key_id = key_id
      @private_key = private_key
      @sleeper = sleeper
    end

    def get(path, query: {})
      request(:get, path, query: query)
    end

    def post(path, body:)
      request(:post, path, body: body)
    end

    def patch(path, body:)
      request(:patch, path, body: body)
    end

    def collection(path, query: {})
      resources = []
      next_url = with_query(path, query)
      pages = 0

      while next_url
        pages += 1
        raise Error, "App Store Connect pagination exceeded 20 pages" if pages > 20

        response = request(:get, next_url)
        resources.concat(response.fetch("data"))
        next_url = response.dig("links", "next")
      end
      resources
    end

    private

    def with_query(path, query)
      return path if query.empty?

      separator = path.include?("?") ? "&" : "?"
      "#{path}#{separator}#{URI.encode_www_form(query)}"
    end

    def request(method, path, query: {}, body: nil)
      uri = path.start_with?("http") ? URI(path) : URI("#{API_ROOT}#{path}")
      uri.query = URI.encode_www_form(query) unless query.empty?
      attempts = 0

      loop do
        attempts += 1
        request = request_class(method).new(uri)
        request["Authorization"] = "Bearer #{token}"
        request["Accept"] = "application/json"
        if body
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(body)
        end

        response = Net::HTTP.start(
          uri.hostname,
          uri.port,
          use_ssl: true,
          open_timeout: 15,
          read_timeout: 60
        ) { |http| http.request(request) }

        if response.is_a?(Net::HTTPSuccess)
          return {} if response.body.nil? || response.body.empty?

          return JSON.parse(response.body)
        end

        if retryable?(method, response) && attempts < 5
          wait = [response["Retry-After"].to_i, 2**attempts].max
          @sleeper.call([wait, 30].min)
          next
        end

        raise Error, error_message(response)
      end
    rescue JSON::ParserError
      raise Error, "App Store Connect returned invalid JSON"
    rescue OpenSSL::PKey::PKeyError
      raise Error, "The App Store Connect private key is invalid"
    rescue Timeout::Error, SocketError, EOFError, SystemCallError, OpenSSL::SSL::SSLError => error
      raise TransportError, "App Store Connect transport failed: #{error.class}"
    end

    def token
      AppStoreConnect.jwt(
        issuer_id: @issuer_id,
        key_id: @key_id,
        private_key: @private_key
      )
    end

    def request_class(method)
      { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method)
    end

    def retryable?(method, response)
      return false if method == :post

      response.code.to_i == 429 || response.code.to_i >= 500
    end

    def error_message(response)
      errors = JSON.parse(response.body.to_s).fetch("errors", [])
      details = errors.filter_map do |error|
        [error["code"], error["title"], error["detail"]].compact.join(": ")
      end
      detail = details.empty? ? "No error detail was returned" : details.join("; ")
      "App Store Connect returned HTTP #{response.code}: #{detail}"
    rescue JSON::ParserError
      "App Store Connect returned HTTP #{response.code} with an unreadable error response"
    end
  end

  class ReleaseManager
    def initialize(
      client:,
      app_id:,
      output_path: ENV["GITHUB_OUTPUT"],
      summary_path: ENV["GITHUB_STEP_SUMMARY"],
      sleeper: ->(seconds) { sleep(seconds) },
      release_reconciliation_attempts: 30,
      release_reconciliation_delay: 10
    )
      @client = client
      @app_id = app_id
      @output_path = output_path
      @summary_path = summary_path
      @sleeper = sleeper
      @release_reconciliation_attempts = release_reconciliation_attempts
      @release_reconciliation_delay = release_reconciliation_delay
    end

    def inspect_build(platform:, version:, build_number:)
      build = find_build(platform: platform, version: version, build_number: build_number)
      state = build&.dig("attributes", "processingState") || "MISSING"
      write_output("exists", (!build.nil?).to_s)
      write_output("processing_state", state)
      write_output("build_id", build&.fetch("id", "").to_s)
      puts "#{platform} #{version} (#{build_number}): #{state}"
      build
    end

    def wait_for_builds(version:, build_number:, timeout_seconds: 2_700, poll_seconds: 30)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
      loop do
        builds = PLATFORMS.to_h do |platform|
          [platform, find_build(platform: platform, version: version, build_number: build_number)]
        end

        failures = builds.filter_map do |platform, build|
          state = build&.dig("attributes", "processingState")
          "#{platform}=#{state}" if %w[FAILED INVALID].include?(state)
        end
        raise Error, "Apple rejected build processing: #{failures.join(", ")}" unless failures.empty?

        if builds.values.all? { |build| build&.dig("attributes", "processingState") == "VALID" }
          builds.each_value { |build| validate_export_compliance(build) }
          append_summary("Both App Store Connect builds are processed and valid.")
          return builds
        end

        states = builds.map do |platform, build|
          "#{platform}=#{build&.dig("attributes", "processingState") || "MISSING"}"
        end
        raise Error, "Timed out while Apple processed builds: #{states.join(", ")}" if monotonic_time >= deadline

        puts "Waiting for App Store Connect processing: #{states.join(", ")}"
        sleep(poll_seconds)
      end
    end

    def distribute_internal(version:, build_number:, group_name: nil)
      builds = require_valid_builds(version: version, build_number: build_number)
      group = find_or_create_group(name: group_name, internal: true)
      disable_mobile_builds_on_other_platforms(group)
      add_builds_to_group(group.fetch("id"), builds.values.map { |build| build.fetch("id") })
      append_summary("Distributed #{version} (#{build_number}) to internal group #{group.dig("attributes", "name")}.")
    end

    def distribute_external(version:, build_number:, group_name:, localization_paths:)
      builds = require_valid_builds(version: version, build_number: build_number)
      validate_beta_app_localizations
      validate_beta_review_details
      unless beta_groups.any? { |group| group.dig("attributes", "isInternalGroup") == true }
        raise Error, "Create an internal TestFlight group before distributing to external testers"
      end
      group = find_or_create_group(name: group_name, internal: false)
      disable_mobile_builds_on_other_platforms(group)

      builds.each_value do |build|
        upsert_build_localizations(build.fetch("id"), localization_paths)
      end
      add_builds_to_group(group.fetch("id"), builds.values.map { |build| build.fetch("id") })
      builds.each_value { |build| submit_beta_review(build) }
      append_summary("Submitted #{version} (#{build_number}) for external TestFlight testing in #{group_name}.")
    end

    def prepare_app_store(version:, build_number:, submit: false)
      builds = require_valid_builds(version: version, build_number: build_number)
      versions = PLATFORMS.to_h do |platform|
        app_store_version = require_app_store_version(platform: platform, version: version)
        [platform, app_store_version]
      end
      states = versions.transform_values { |item| version_state(item) }
      invalid = states.reject do |_platform, state|
        SUBMITTED_VERSION_STATES.include?(state) || %w[PREPARE_FOR_SUBMISSION READY_FOR_REVIEW].include?(state)
      end
      unless invalid.empty?
        raise Error, "App versions cannot use this release workflow from states: #{invalid.map { |key, value| "#{key}=#{value}" }.join(", ")}"
      end

      versions.each do |platform, app_store_version|
        build_id = builds.fetch(platform).fetch("id")
        if SUBMITTED_VERSION_STATES.include?(states.fetch(platform))
          require_attached_build(app_store_version.fetch("id"), build_id)
        else
          attach_build(app_store_version.fetch("id"), build_id)
        end
      end

      unless submit
        append_summary("Attached both #{version} (#{build_number}) builds. App Review was not started.")
        return
      end

      if states.values.all? { |state| SUBMITTED_VERSION_STATES.include?(state) }
        append_summary("Both app versions are already submitted or approved.")
        return
      end

      versions.each do |platform, app_store_version|
        next if SUBMITTED_VERSION_STATES.include?(states.fetch(platform))

        submission = find_or_create_review_submission(platform: platform)
        add_version_to_review_submission(
          submission_id: submission.fetch("id"),
          version_id: app_store_version.fetch("id")
        )
        @client.patch(
          "/v1/reviewSubmissions/#{submission.fetch("id")}",
          body: AppStoreConnect.submit_review_payload(submission.fetch("id"))
        )
      end
      append_summary("Submitted both #{version} (#{build_number}) app versions to App Review.")
    end

    def release_app_store(version:, permit_requests: true)
      versions = PLATFORMS.to_h do |platform|
        [platform, require_app_store_version(platform: platform, version: version)]
      end
      non_manual = versions.reject do |_platform, app_store_version|
        app_store_version.dig("attributes", "releaseType") == "MANUAL"
      end
      unless non_manual.empty?
        types = non_manual.map do |platform, item|
          "#{platform}=#{item.dig("attributes", "releaseType") || "UNKNOWN"}"
        end
        raise Error, "App versions must use manual release: #{types.join(", ")}"
      end

      releasable = versions.select do |_platform, app_store_version|
        version_state(app_store_version) == "PENDING_DEVELOPER_RELEASE"
      end
      complete = versions.reject do |_platform, app_store_version|
        %w[
          PENDING_DEVELOPER_RELEASE PENDING_APPLE_RELEASE PROCESSING_FOR_DISTRIBUTION
          READY_FOR_DISTRIBUTION READY_FOR_SALE
        ].include?(
          version_state(app_store_version)
        )
      end
      unless complete.empty?
        states = complete.map { |platform, item| "#{platform}=#{version_state(item)}" }
        raise Error, "App versions are not ready for manual release: #{states.join(", ")}"
      end

      if !permit_requests && !releasable.empty?
        platforms = releasable.keys.join(" and ")
        raise Error,
              "A release lock exists while Apple still reports #{platforms} as pending developer release. " \
              "Verify App Store Connect before removing the GitHub release lock ref."
      end

      releasable.each do |platform, app_store_version|
        begin
          @client.post(
            "/v1/appStoreVersionReleaseRequests",
            body: AppStoreConnect.release_request_payload(app_store_version.fetch("id"))
          )
        rescue TransportError => error
          if release_request_accepted?(platform: platform, version: version)
            puts "Reconciled #{platform} after an uncertain release-request response."
            next
          end
          raise error
        end
      end
      if releasable.empty?
        append_summary("Both #{version} platforms are already released or processing.")
      else
        platforms = releasable.keys.join(" and ")
        append_summary("Requested the App Store release for #{platforms} #{version}.")
      end
    end

    private

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def release_request_accepted?(platform:, version:)
      @release_reconciliation_attempts.times do |attempt|
        begin
          refreshed = require_app_store_version(platform: platform, version: version)
          return true if %w[
            PENDING_APPLE_RELEASE PROCESSING_FOR_DISTRIBUTION READY_FOR_DISTRIBUTION READY_FOR_SALE
          ].include?(version_state(refreshed))
        rescue TransportError
          # Continue polling because the release status remains uncertain.
        end

        @sleeper.call(@release_reconciliation_delay) if attempt + 1 < @release_reconciliation_attempts
      end
      false
    end

    def find_build(platform:, version:, build_number:)
      raise Error, "Unsupported platform #{platform}" unless PLATFORMS.include?(platform)

      builds = @client.collection(
        "/v1/builds",
        query: AppStoreConnect.build_filters(
          app_id: @app_id,
          version: version,
          build_number: build_number,
          platform: platform
        )
      )
      raise Error, "Apple returned more than one #{platform} build for #{version} (#{build_number})" if builds.length > 1

      builds.first
    end

    def require_valid_builds(version:, build_number:)
      PLATFORMS.to_h do |platform|
        build = find_build(platform: platform, version: version, build_number: build_number)
        raise Error, "Missing #{platform} build #{version} (#{build_number})" unless build

        state = build.dig("attributes", "processingState")
        raise Error, "#{platform} build is #{state}, not VALID" unless state == "VALID"

        validate_export_compliance(build)
        [platform, build]
      end
    end

    def validate_export_compliance(build)
      value = build.dig("attributes", "usesNonExemptEncryption")
      return if value == false

      raise Error, "Build #{build.fetch("id")} does not declare exempt encryption"
    end

    def beta_groups
      @client.collection("/v1/apps/#{@app_id}/betaGroups", query: { "limit" => "200" })
    end

    def find_or_create_group(name:, internal:)
      candidates = beta_groups.select { |group| group.dig("attributes", "isInternalGroup") == internal }
      if name && !name.strip.empty?
        match = candidates.find { |group| group.dig("attributes", "name") == name }
        return match if match

        response = @client.post(
          "/v1/betaGroups",
          body: AppStoreConnect.beta_group_payload(app_id: @app_id, name: name, internal: internal)
        )
        return response.fetch("data")
      end

      return candidates.first if candidates.length == 1

      names = candidates.map { |group| group.dig("attributes", "name") }.compact
      raise Error, "Specify a beta group. Available groups: #{names.empty? ? "none" : names.join(", ")}"
    end

    def add_builds_to_group(group_id, build_ids)
      existing_ids = @client.collection(
        "/v1/betaGroups/#{group_id}/builds",
        query: { "limit" => "200" }
      ).map { |build| build.fetch("id") }
      missing = build_ids - existing_ids
      return if missing.empty?

      @client.post(
        "/v1/betaGroups/#{group_id}/relationships/builds",
        body: AppStoreConnect.beta_group_builds_payload(missing)
      )
    end

    def disable_mobile_builds_on_other_platforms(group)
      attributes = group.fetch("attributes", {})
      return if attributes["iosBuildsAvailableForAppleSiliconMac"] == false &&
                attributes["iosBuildsAvailableForAppleVision"] == false

      @client.patch(
        "/v1/betaGroups/#{group.fetch("id")}",
        body: {
          data: {
            type: "betaGroups",
            id: group.fetch("id"),
            attributes: {
              iosBuildsAvailableForAppleSiliconMac: false,
              iosBuildsAvailableForAppleVision: false
            }
          }
        }
      )
    end

    def validate_beta_app_localizations
      localizations = @client.collection(
        "/v1/apps/#{@app_id}/betaAppLocalizations",
        query: { "limit" => "50" }
      )
      missing = localizations.filter_map do |localization|
        locale = localization.dig("attributes", "locale")
        description = localization.dig("attributes", "description").to_s.strip
        locale if description.empty?
      end
      if localizations.empty? || !missing.empty?
        labels = localizations.empty? ? "all locales" : missing.join(", ")
        raise Error, "TestFlight app descriptions are missing for #{labels}"
      end
    end

    def validate_beta_review_details
      details = @client.collection(
        "/v1/betaAppReviewDetails",
        query: { "filter[app]" => @app_id, "limit" => "10" }
      )
      raise Error, "TestFlight beta review contact information is missing" if details.empty?
      raise Error, "Apple returned multiple beta review detail records" if details.length > 1

      attributes = details.first.fetch("attributes", {})
      required = %w[contactFirstName contactLastName contactPhone contactEmail]
      missing = required.select { |name| attributes[name].to_s.strip.empty? }
      unless missing.empty?
        raise Error, "TestFlight beta review fields are missing: #{missing.join(", ")}"
      end
      phone = attributes.fetch("contactPhone").strip
      unless phone.match?(/\A\+[1-9][0-9]{7,14}\z/)
        raise Error, "TestFlight beta review contact phone must use international E.164 format"
      end

      return unless attributes["demoAccountRequired"] == true

      account_fields = %w[demoAccountName demoAccountPassword]
      missing_account_fields = account_fields.select { |name| attributes[name].to_s.empty? }
      unless missing_account_fields.empty?
        raise Error, "TestFlight demo account fields are missing: #{missing_account_fields.join(", ")}"
      end
    end

    def upsert_build_localizations(build_id, localization_paths)
      existing = @client.collection(
        "/v1/builds/#{build_id}/betaBuildLocalizations",
        query: { "limit" => "50" }
      ).to_h { |item| [item.dig("attributes", "locale"), item] }

      localization_paths.each do |locale, path|
        text = File.read(path, encoding: "UTF-8").strip
        raise Error, "TestFlight text is empty for #{locale}" if text.empty?

        item = existing[locale]
        if item
          @client.patch(
            "/v1/betaBuildLocalizations/#{item.fetch("id")}",
            body: {
              data: {
                type: "betaBuildLocalizations",
                id: item.fetch("id"),
                attributes: { whatsNew: text }
              }
            }
          )
        else
          @client.post(
            "/v1/betaBuildLocalizations",
            body: {
              data: {
                type: "betaBuildLocalizations",
                attributes: { locale: locale, whatsNew: text },
                relationships: { build: { data: { type: "builds", id: build_id } } }
              }
            }
          )
        end
      end
    end

    def submit_beta_review(build)
      response = @client.get(
        "/v1/builds/#{build.fetch("id")}",
        query: { "include" => "betaAppReviewSubmission" }
      )
      relationship = response.dig("data", "relationships", "betaAppReviewSubmission", "data")
      submission = response.fetch("included", []).find do |item|
        relationship && item["type"] == "betaAppReviewSubmissions" && item["id"] == relationship["id"]
      end
      state = submission&.dig("attributes", "betaReviewState")
      return if REVIEWED_BUILD_STATES.include?(state)
      raise Error, "Build #{build.fetch("id")} was rejected by TestFlight review" if state == "REJECTED"

      @client.post(
        "/v1/betaAppReviewSubmissions",
        body: AppStoreConnect.beta_review_payload(build.fetch("id"))
      )
    end

    def require_app_store_version(platform:, version:)
      versions = @client.collection(
        "/v1/apps/#{@app_id}/appStoreVersions",
        query: {
          "filter[platform]" => platform,
          "filter[versionString]" => version,
          "limit" => "10"
        }
      )
      raise Error, "Missing #{platform} App Store version #{version}" if versions.empty?
      raise Error, "Apple returned multiple #{platform} App Store versions for #{version}" if versions.length > 1

      versions.first
    end

    def find_or_create_review_submission(platform:)
      submissions = @client.collection(
        "/v1/reviewSubmissions",
        query: {
          "filter[app]" => @app_id,
          "filter[platform]" => platform,
          "limit" => "200"
        }
      )
      ready = submissions.select { |item| item.dig("attributes", "state") == "READY_FOR_REVIEW" }
      raise Error, "Apple returned multiple open #{platform} review submissions" if ready.length > 1
      return ready.first if ready.one?

      response = @client.post(
        "/v1/reviewSubmissions",
        body: AppStoreConnect.review_submission_payload(app_id: @app_id, platform: platform)
      )
      response.fetch("data")
    end

    def add_version_to_review_submission(submission_id:, version_id:)
      items = @client.collection(
        "/v1/reviewSubmissions/#{submission_id}/items",
        query: { "limit" => "200", "include" => "appStoreVersion" }
      )
      exists = items.any? do |item|
        item.dig("relationships", "appStoreVersion", "data", "id") == version_id
      end
      return if exists

      other_version_ids = items.filter_map do |item|
        item.dig("relationships", "appStoreVersion", "data", "id")
      end.uniq
      unless other_version_ids.empty?
        raise Error, "Open review submission #{submission_id} already contains another app version"
      end

      @client.post(
        "/v1/reviewSubmissionItems",
        body: AppStoreConnect.review_item_payload(
          submission_id: submission_id,
          version_id: version_id
        )
      )
    end

    def attach_build(version_id, build_id)
      @client.patch(
        "/v1/appStoreVersions/#{version_id}/relationships/build",
        body: AppStoreConnect.app_store_build_payload(build_id)
      )
    end

    def require_attached_build(version_id, expected_build_id)
      response = @client.get("/v1/appStoreVersions/#{version_id}/relationships/build")
      actual_build_id = response.dig("data", "id")
      return if actual_build_id == expected_build_id

      raise Error, "Submitted app version #{version_id} uses a different build"
    end

    def version_state(app_store_version)
      attributes = app_store_version.fetch("attributes")
      attributes["appVersionState"] || attributes["appStoreState"] || "UNKNOWN"
    end

    def write_output(name, value)
      return unless @output_path && !@output_path.empty?

      File.open(@output_path, "a") { |file| file.puts("#{name}=#{value}") }
    end

    def append_summary(message)
      puts message
      return unless @summary_path && !@summary_path.empty?

      File.open(@summary_path, "a") { |file| file.puts("- #{message}") }
    end
  end

  class CLI
    def self.run(argv)
      command = argv.shift
      options = parse_options(argv)
      manager = manager_from_environment
      version = required_option(options, :version)

      case command
      when "inspect-build"
        build_number = required_option(options, :build_number)
        manager.inspect_build(
          platform: required_option(options, :platform),
          version: version,
          build_number: build_number
        )
      when "wait-builds"
        build_number = required_option(options, :build_number)
        manager.wait_for_builds(
          version: version,
          build_number: build_number,
          timeout_seconds: options.fetch(:timeout, 2_700)
        )
      when "distribute-internal"
        build_number = required_option(options, :build_number)
        manager.distribute_internal(
          version: version,
          build_number: build_number,
          group_name: options[:group]
        )
      when "distribute-external"
        build_number = required_option(options, :build_number)
        manager.distribute_external(
          version: version,
          build_number: build_number,
          group_name: required_option(options, :group),
          localization_paths: required_option(options, :localizations)
        )
      when "prepare-app-store"
        build_number = required_option(options, :build_number)
        manager.prepare_app_store(
          version: version,
          build_number: build_number,
          submit: options.fetch(:submit, false)
        )
      when "release-app-store"
        manager.release_app_store(version: version)
      when "verify-release-state"
        manager.release_app_store(version: version, permit_requests: false)
      else
        raise Error, "Unknown command #{command.inspect}"
      end
    rescue Error, KeyError, ArgumentError => error
      warn "Apple release action failed: #{error.message}"
      exit 1
    end

    def self.parse_options(argv)
      options = { localizations: {} }
      OptionParser.new do |parser|
        parser.on("--platform PLATFORM") { |value| options[:platform] = value }
        parser.on("--version VERSION") { |value| options[:version] = value }
        parser.on("--build-number NUMBER") { |value| options[:build_number] = value }
        parser.on("--group NAME") { |value| options[:group] = value }
        parser.on("--timeout SECONDS", Integer) { |value| options[:timeout] = value }
        parser.on("--submit") { options[:submit] = true }
        parser.on("--localization LOCALE=PATH") do |value|
          locale, path = value.split("=", 2)
          raise OptionParser::InvalidArgument, value unless locale && path

          options[:localizations][locale] = path
        end
      end.parse!(argv)
      options
    end

    def self.manager_from_environment
      private_key = Base64.strict_decode64(required_env("APP_STORE_CONNECT_PRIVATE_KEY_BASE64"))
      client = Client.new(
        issuer_id: required_env("APP_STORE_CONNECT_ISSUER_ID"),
        key_id: required_env("APP_STORE_CONNECT_KEY_ID"),
        private_key: private_key
      )
      ReleaseManager.new(client: client, app_id: required_env("APP_STORE_CONNECT_APP_ID"))
    rescue ArgumentError
      raise Error, "APP_STORE_CONNECT_PRIVATE_KEY_BASE64 is not valid Base64"
    end

    def self.required_env(name)
      value = ENV.fetch(name, "").strip
      raise Error, "Missing #{name}" if value.empty?

      value
    end

    def self.required_option(options, name)
      value = options[name]
      raise Error, "Missing --#{name.to_s.tr("_", "-")}" if value.nil? || value.respond_to?(:empty?) && value.empty?

      value
    end
  end
end

AppStoreConnect::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
