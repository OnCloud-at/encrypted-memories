#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "openssl"
require "tempfile"
require_relative "app_store_connect"

class FakeAppStoreConnectClient
  attr_reader :calls

  def initialize(
    version_state: "PREPARE_FOR_SUBMISSION",
    release_type: "MANUAL",
    groups: nil,
    review_items: [],
    beta_phone: "+431234567"
  )
    @version_state = version_state
    @release_type = release_type
    @groups = groups
    @review_items = review_items
    @beta_phone = beta_phone
    @calls = []
  end

  def collection(path, query: {})
    @calls << [:collection, path, query]
    case path
    when "/v1/builds"
      platform = query.fetch("filter[preReleaseVersion.platform]")
      [build(platform)]
    when "/v1/apps/6805117080/betaGroups"
      @groups || [group("Internal Testers", true), group("External Testers", false)]
    when %r{\A/v1/betaGroups/.+/builds\z}
      []
    when "/v1/apps/6805117080/betaAppLocalizations"
      [{ "attributes" => { "locale" => "en-US", "description" => "A native photo library." } }]
    when "/v1/betaAppReviewDetails"
      [{
        "id" => "beta-review-details",
        "attributes" => {
          "contactFirstName" => "App",
          "contactLastName" => "Reviewer",
          "contactPhone" => @beta_phone,
          "contactEmail" => "review@example.com",
          "demoAccountRequired" => false
        }
      }]
    when %r{\A/v1/builds/.+/betaBuildLocalizations\z}
      []
    when "/v1/apps/6805117080/appStoreVersions"
      platform = query.fetch("filter[platform]")
      state = @version_state.respond_to?(:fetch) ? @version_state.fetch(platform) : @version_state
      [{
        "type" => "appStoreVersions",
        "id" => "version-#{platform}",
        "attributes" => { "appVersionState" => state, "releaseType" => @release_type }
      }]
    when "/v1/reviewSubmissions"
      []
    when %r{\A/v1/reviewSubmissions/.+/items\z}
      @review_items
    else
      raise "Unexpected collection #{path}"
    end
  end

  def get(path, query: {})
    @calls << [:get, path, query]
    if path.match?(%r{\A/v1/appStoreVersions/.+/relationships/build\z})
      platform = path.include?("MAC_OS") ? "MAC_OS" : "IOS"
      return { "data" => { "type" => "builds", "id" => "build-#{platform}" } }
    end

    {
      "data" => {
        "relationships" => {
          "betaAppReviewSubmission" => { "data" => nil }
        }
      },
      "included" => []
    }
  end

  def post(path, body:)
    @calls << [:post, path, body]
    if path == "/v1/reviewSubmissions"
      platform = body.dig(:data, :attributes, :platform)
      return {
        "data" => {
          "id" => "review-submission-#{platform}",
          "attributes" => { "platform" => platform, "state" => "READY_FOR_REVIEW" }
        }
      }
    end

    { "data" => { "id" => "created" } }
  end

  def patch(path, body:)
    @calls << [:patch, path, body]
    { "data" => { "id" => "updated" } }
  end

  private

  def build(platform)
    {
      "type" => "builds",
      "id" => "build-#{platform}",
      "attributes" => {
        "processingState" => "VALID",
        "usesNonExemptEncryption" => false
      }
    }
  end

  def group(name, internal)
    {
      "type" => "betaGroups",
      "id" => "group-#{internal ? "internal" : "external"}",
      "attributes" => {
        "name" => name,
        "isInternalGroup" => internal,
        "iosBuildsAvailableForAppleSiliconMac" => true,
        "iosBuildsAvailableForAppleVision" => true
      }
    }
  end
end

class AppStoreConnectTest < Minitest::Test
  def setup
    @client = FakeAppStoreConnectClient.new
    @manager = AppStoreConnect::ReleaseManager.new(
      client: @client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )
  end

  def test_jwt_uses_a_valid_es256_signature
    key = OpenSSL::PKey::EC.generate("prime256v1")
    token = AppStoreConnect.jwt(
      issuer_id: "issuer",
      key_id: "KEY123",
      private_key: key.to_pem,
      now: 1_700_000_000
    )
    header, claims, raw_signature = token.split(".").map { |part| Base64.urlsafe_decode64(part) }

    assert_equal({ "alg" => "ES256", "kid" => "KEY123", "typ" => "JWT" }, JSON.parse(header))
    assert_equal 1_700_001_200, JSON.parse(claims).fetch("exp")
    assert_equal 64, raw_signature.bytesize

    r = OpenSSL::BN.new(raw_signature.byteslice(0, 32), 2)
    s = OpenSSL::BN.new(raw_signature.byteslice(32, 32), 2)
    der = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::Integer(r), OpenSSL::ASN1::Integer(s)]).to_der
    assert key.verify(OpenSSL::Digest.new("SHA256"), der, token.split(".").first(2).join("."))
  end

  def test_build_lookup_requires_app_store_eligible_platform_build
    filters = AppStoreConnect.build_filters(
      app_id: "6805117080",
      version: "1.0.0",
      build_number: "714",
      platform: "IOS"
    )

    assert_equal "6805117080", filters.fetch("filter[app]")
    assert_equal "1.0.0", filters.fetch("filter[preReleaseVersion.version]")
    assert_equal "714", filters.fetch("filter[version]")
    assert_equal "IOS", filters.fetch("filter[preReleaseVersion.platform]")
    assert_equal "APP_STORE_ELIGIBLE", filters.fetch("filter[buildAudienceType]")
  end

  def test_beta_group_create_uses_only_attributes_allowed_by_the_create_contract
    payload = AppStoreConnect.beta_group_payload(
      app_id: "6805117080",
      name: "Internal Testers",
      internal: true
    )
    attributes = payload.dig(:data, :attributes)

    assert_equal true, attributes.fetch(:isInternalGroup)
    refute attributes.key?(:iosBuildsAvailableForAppleSiliconMac)
    refute attributes.key?(:iosBuildsAvailableForAppleVision)
  end

  def test_client_does_not_blindly_retry_mutating_posts_after_server_errors
    client = AppStoreConnect::Client.new(
      issuer_id: "issuer",
      key_id: "key",
      private_key: OpenSSL::PKey::EC.generate("prime256v1").to_pem,
      sleeper: ->(_seconds) {}
    )
    unavailable = Net::HTTPServiceUnavailable.new("1.1", "503", "Unavailable")
    rate_limited = Net::HTTPTooManyRequests.new("1.1", "429", "Rate limited")

    assert_equal false, client.send(:retryable?, :post, unavailable)
    assert_equal true, client.send(:retryable?, :get, unavailable)
    assert_equal false, client.send(:retryable?, :post, rate_limited)
    assert_equal true, client.send(:retryable?, :patch, rate_limited)
  end

  def test_internal_distribution_adds_both_platform_builds
    @manager.distribute_internal(
      version: "1.0.0",
      build_number: "714",
      group_name: "Internal Testers"
    )

    call = @client.calls.find do |method, path, _body|
      method == :post && path == "/v1/betaGroups/group-internal/relationships/builds"
    end
    refute_nil call
    ids = call.last.fetch(:data).map { |item| item.fetch(:id) }
    assert_equal %w[build-IOS build-MAC_OS], ids

    compatibility_call = @client.calls.find do |method, path, _body|
      method == :patch && path == "/v1/betaGroups/group-internal"
    end
    assert_equal false, compatibility_call.last.dig(:data, :attributes, :iosBuildsAvailableForAppleSiliconMac)
  end

  def test_external_distribution_sets_test_text_and_submits_both_builds
    file = Tempfile.new("what-to-test")
    file.write("Test sign-in and backup.")
    file.close

    @manager.distribute_external(
      version: "1.0.0",
      build_number: "714",
      group_name: "External Testers",
      localization_paths: { "en-US" => file.path }
    )

    localization_posts = @client.calls.count do |method, path, _body|
      method == :post && path == "/v1/betaBuildLocalizations"
    end
    review_posts = @client.calls.count do |method, path, _body|
      method == :post && path == "/v1/betaAppReviewSubmissions"
    end
    assert_equal 2, localization_posts
    assert_equal 2, review_posts
  ensure
    file&.unlink
  end

  def test_external_distribution_requires_an_internal_group
    client = FakeAppStoreConnectClient.new(groups: [{
      "id" => "external",
      "attributes" => { "name" => "External Testers", "isInternalGroup" => false }
    }])
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) do
      manager.distribute_external(
        version: "1.0.0",
        build_number: "714",
        group_name: "External Testers",
        localization_paths: { "en-US" => __FILE__ }
      )
    end
    assert_match(/internal TestFlight group/, error.message)
  end

  def test_external_distribution_requires_an_e164_review_phone
    client = FakeAppStoreConnectClient.new(beta_phone: "0043 123 456")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) do
      manager.distribute_external(
        version: "1.0.0",
        build_number: "714",
        group_name: "External Testers",
        localization_paths: { "en-US" => __FILE__ }
      )
    end
    assert_match(/E.164/, error.message)
  end

  def test_app_store_submission_uses_one_review_submission_per_platform
    @manager.prepare_app_store(version: "1.0.0", build_number: "714", submit: true)

    attachment_calls = @client.calls.count do |method, path, _body|
      method == :patch && path.match?(%r{\A/v1/appStoreVersions/.+/relationships/build\z})
    end
    item_calls = @client.calls.count do |method, path, _body|
      method == :post && path == "/v1/reviewSubmissionItems"
    end
    submission_posts = @client.calls.select do |method, path, _body|
      method == :post && path == "/v1/reviewSubmissions"
    end
    submit_calls = @client.calls.select do |method, path, _body|
      method == :patch && path.start_with?("/v1/reviewSubmissions/review-submission-")
    end

    assert_equal 2, attachment_calls
    assert_equal %w[IOS MAC_OS], submission_posts.map { |_method, _path, body| body.dig(:data, :attributes, :platform) }
    assert_equal 2, item_calls
    assert_equal 2, submit_calls.length
    assert submit_calls.all? { |_method, _path, body| body.dig(:data, :attributes, :submitted) == true }
  end


  def test_app_store_rerun_validates_builds_without_duplicate_review_submissions
    client = FakeAppStoreConnectClient.new(version_state: "WAITING_FOR_REVIEW")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    manager.prepare_app_store(version: "1.0.0", build_number: "714", submit: true)

    review_posts = client.calls.count do |method, path, _body|
      method == :post && path == "/v1/reviewSubmissions"
    end
    attachment_patches = client.calls.count do |method, path, _body|
      method == :patch && path.match?(%r{\A/v1/appStoreVersions/.+/relationships/build\z})
    end
    assert_equal 0, review_posts
    assert_equal 0, attachment_patches
  end

  def test_app_store_rerun_finishes_only_the_platform_that_is_not_submitted
    client = FakeAppStoreConnectClient.new(
      version_state: { "IOS" => "WAITING_FOR_REVIEW", "MAC_OS" => "PREPARE_FOR_SUBMISSION" }
    )
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    manager.prepare_app_store(version: "1.0.0", build_number: "714", submit: true)

    submission_platforms = client.calls.filter_map do |method, path, body|
      body.dig(:data, :attributes, :platform) if method == :post && path == "/v1/reviewSubmissions"
    end
    attachment_paths = client.calls.filter_map do |method, path, _body|
      path if method == :patch && path.match?(%r{\A/v1/appStoreVersions/.+/relationships/build\z})
    end
    assert_equal ["MAC_OS"], submission_platforms
    assert_equal ["/v1/appStoreVersions/version-MAC_OS/relationships/build"], attachment_paths
  end

  def test_open_review_submission_rejects_another_app_version
    client = FakeAppStoreConnectClient.new(review_items: [{
      "id" => "existing-item",
      "relationships" => {
        "appStoreVersion" => { "data" => { "type" => "appStoreVersions", "id" => "other-version" } }
      }
    }])
    def client.collection(path, query: {})
      return [{ "id" => "open", "attributes" => { "state" => "READY_FOR_REVIEW" } }] if path == "/v1/reviewSubmissions"

      super
    end
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) do
      manager.prepare_app_store(version: "1.0.0", build_number: "714", submit: true)
    end
    assert_match(/already contains another app version/, error.message)
  end

  def test_manual_release_requests_each_approved_platform
    client = FakeAppStoreConnectClient.new(version_state: "PENDING_DEVELOPER_RELEASE")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    manager.release_app_store(version: "1.0.0")

    version_ids = client.calls.filter_map do |method, path, body|
      if method == :post && path == "/v1/appStoreVersionReleaseRequests"
        body.dig(:data, :relationships, :appStoreVersion, :data, :id)
      end
    end
    assert_equal %w[version-IOS version-MAC_OS], version_ids
  end

  def test_manual_release_accepts_pending_apple_release_as_idempotent
    client = FakeAppStoreConnectClient.new(
      version_state: { "IOS" => "PENDING_APPLE_RELEASE", "MAC_OS" => "PENDING_DEVELOPER_RELEASE" }
    )
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    manager.release_app_store(version: "1.0.0")

    version_ids = client.calls.filter_map do |method, path, body|
      if method == :post && path == "/v1/appStoreVersionReleaseRequests"
        body.dig(:data, :relationships, :appStoreVersion, :data, :id)
      end
    end
    assert_equal ["version-MAC_OS"], version_ids
  end

  def test_manual_release_rejects_automatic_release_type
    client = FakeAppStoreConnectClient.new(
      version_state: "PENDING_DEVELOPER_RELEASE",
      release_type: "AFTER_APPROVAL"
    )
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) do
      manager.release_app_store(version: "1.0.0")
    end
    assert_match(/must use manual release/, error.message)
  end

  def test_manual_release_reconciles_an_uncertain_post_response
    client = FakeAppStoreConnectClient.new(
      version_state: { "IOS" => "PENDING_DEVELOPER_RELEASE", "MAC_OS" => "READY_FOR_DISTRIBUTION" }
    )
    posted = false
    client.define_singleton_method(:post) do |path, body:|
      unless posted || path != "/v1/appStoreVersionReleaseRequests"
        posted = true
        @calls << [:post, path, body]
        @version_state = { "IOS" => "PENDING_APPLE_RELEASE", "MAC_OS" => "READY_FOR_DISTRIBUTION" }
        raise AppStoreConnect::TransportError, "App Store Connect transport failed: EOFError"
      end
      super(path, body: body)
    end
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    manager.release_app_store(version: "1.0.0")

    assert posted
  end

  def test_release_lock_rejects_a_still_pending_release
    client = FakeAppStoreConnectClient.new(version_state: "PENDING_DEVELOPER_RELEASE")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    error = assert_raises(AppStoreConnect::Error) do
      manager.release_app_store(version: "1.0.0", permit_requests: false)
    end

    assert_match(/release lock exists/, error.message)
    refute client.calls.any? { |method, path, _body| method == :post && path.include?("ReleaseRequests") }
  end

  def test_release_lock_accepts_a_confirmed_release_without_posting
    client = FakeAppStoreConnectClient.new(version_state: "PROCESSING_FOR_DISTRIBUTION")
    manager = AppStoreConnect::ReleaseManager.new(
      client: client,
      app_id: "6805117080",
      output_path: nil,
      summary_path: nil
    )

    manager.release_app_store(version: "1.0.0", permit_requests: false)

    refute client.calls.any? { |method, path, _body| method == :post && path.include?("ReleaseRequests") }
  end
end
