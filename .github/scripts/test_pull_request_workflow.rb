require "minitest/autorun"
require "yaml"
require "open3"
require "tmpdir"

class PullRequestWorkflowTests < Minitest::Test
  WORKFLOWS = File.expand_path("../workflows", __dir__)
  REQUIRED_CHECKS = [
    "Repository hygiene", "Swift style", "Swift package tests", "iOS app tests",
    "Shared architecture", "macOS app shell", "iOS app shell", "iOS UI tests"
  ].freeze

  def setup
    @workflow = YAML.load_file(File.join(WORKFLOWS, "pull-request.yml"))
  end

  def evaluate(expression, context)
    return expression unless expression.is_a?(String)

    # These workflow expressions contain only context lookups and boolean operators.
    source = expression.sub(/\A\$\{\{\s*/, "").sub(/\s*\}\}\z/, "")
    source = source.gsub("always()", "true").gsub("!cancelled()", "true")
    source = source.gsub(/(?:github|inputs|runner)\.[a-z_.]+/) { |path| context.fetch(path, nil).inspect }
    eval(source)
  end

  def diff_steps
    @workflow.fetch("jobs").values.flat_map { |job| job.fetch("steps") }
      .select { |step| step.fetch("env", {}).key?("BASE_SHA") }
  end

  def test_merge_queue_runs_all_required_checks
    assert_equal ["checks_requested"], (@workflow["on"] || @workflow.fetch(true)).fetch("merge_group").fetch("types")
    jobs = @workflow.fetch("jobs").values
    REQUIRED_CHECKS.each do |name|
      job = jobs.find { |candidate| candidate["name"] == name }
      refute_nil job, name
      assert job["if"].nil? || evaluate(job["if"], {"github.event_name" => "merge_group"}), name
    end
  end

  def test_every_diff_step_uses_event_commits
    refute_empty diff_steps
    contexts = [
      [{"github.event.pull_request.base.sha" => "pr-base", "github.event.pull_request.head.sha" => "pr-head", "github.sha" => "merge"}, "pr-base", "pr-head"],
      [{"github.event.merge_group.base_sha" => "queue-base", "github.event.merge_group.head_sha" => "queue-head", "github.sha" => "merge"}, "queue-base", "queue-head"],
      [{"github.sha" => "dispatch-head"}, nil, "dispatch-head"]
    ]
    diff_steps.each do |step|
      contexts.each do |context, base, head|
        actual_base = evaluate(step["env"]["BASE_SHA"], context)
        base.nil? ? assert_nil(actual_base, step["name"]) : assert_equal(base, actual_base, step["name"])
        assert_equal head, evaluate(step["env"]["HEAD_SHA"], context), step["name"]
      end
    end
  end

  def concurrency(context)
    @workflow.fetch("concurrency").fetch("group").gsub(/\$\{\{.*?\}\}/) { |expression| evaluate(expression, context).to_s }
  end

  def test_queue_groups_do_not_cancel_each_other_or_pull_requests
    queue = {"github.event_name" => "merge_group", "github.event.merge_group.head_sha" => "queue-one"}
    other_queue = queue.merge("github.event.merge_group.head_sha" => "queue-two")
    pr = {"github.event_name" => "pull_request", "github.event.pull_request.number" => 42}
    refute_equal concurrency(queue), concurrency(other_queue)
    refute_equal concurrency(queue), concurrency(pr)
    refute evaluate(@workflow["concurrency"]["cancel-in-progress"], queue)
    assert evaluate(@workflow["concurrency"]["cancel-in-progress"], pr)
    assert_equal concurrency(pr), concurrency(pr.merge("github.sha" => "new-head"))
  end

  def test_other_workflows_stay_outside_the_queue
    Dir[File.join(WORKFLOWS, "*.yml")].each do |path|
      next if File.basename(path) == "pull-request.yml"
      refute (YAML.load_file(path)["on"] || YAML.load_file(path).fetch(true)).key?("merge_group"), File.basename(path)
    end
  end
  def test_full_verification_uses_four_mac_runners_without_hygiene_waits
    mac_jobs = @workflow.fetch("jobs").select { |_, job| job["runs-on"] == "xcode-27" }
    assert_equal ["ios-ui-verification", "ios-verification", "macos-verification", "package-verification"], mac_jobs.keys.sort
    mac_jobs.each_value { |job| refute job.key?("needs") }
  end

  def test_queue_guard_runs_only_for_pull_requests
    guard = @workflow.fetch("jobs").fetch("repository-hygiene").fetch("steps")
      .find { |step| step["run"].to_s.include?("require_merge_queue.py") }
    refute_nil guard
    assert evaluate(guard.fetch("if"), {"github.event_name" => "pull_request"})
    ["merge_group", "workflow_dispatch"].each do |event|
      refute evaluate(guard.fetch("if"), {"github.event_name" => event})
    end
    assert_includes guard.fetch("run"), '"$GITHUB_REPOSITORY"'
  end

  def test_pull_requests_skip_heavy_apple_jobs_but_keep_style
    jobs = @workflow.fetch("jobs")
    ["ios-verification", "macos-verification"].each do |id|
      condition = jobs.fetch(id).fetch("if")
      refute evaluate(condition, {"github.event_name" => "pull_request"})
      ["merge_group", "workflow_dispatch"].each do |event|
        assert evaluate(condition, {"github.event_name" => event})
      end
    end
    package = jobs.fetch("package-verification")
    refute package.key?("if")
    tests = package.fetch("steps").find { |step| step["id"] == "tests" }
    refute evaluate(tests.fetch("if"), {"github.event_name" => "pull_request"})
  end

  def test_simulator_build_includes_both_test_bundles
    project = YAML.load_file(File.join(WORKFLOWS, "../../project.yml"))
    scheme = project.fetch("schemes").fetch("EncryptedMemoriesMobileCI")
    assert_equal ["EncryptedMemoriesMobileTests", "EncryptedMemoriesMobileUITests"], scheme.fetch("test").fetch("targets")
  end

  def test_xcode_cache_measurement_has_only_one_writer
    ios = @workflow.fetch("jobs").fetch("ios-verification").fetch("steps")
      .find { |step| step["uses"] == "./.github/actions/prepare-apple-build" }
    macos = @workflow.fetch("jobs").fetch("macos-verification").fetch("steps")
      .find { |step| step["uses"] == "./.github/actions/prepare-apple-build" }
    assert_equal "false", macos.fetch("with").fetch("save-cache")
    refute macos.fetch("with").fetch("measure-cache", false)
    refute_equal "false", ios.fetch("with").fetch("save-cache", "true")
    assert_includes ios.fetch("with").fetch("measure-cache"), "inputs.measure_cache"
    action = YAML.load_file(File.join(WORKFLOWS, "../actions/prepare-apple-build/action.yml"))
    save = action.fetch("runs").fetch("steps").find { |step| step["name"] == "Save resolved Xcode dependencies" }
    assert_includes save.fetch("if"), "inputs.save-cache != 'false'"
  end

  def test_failed_ui_jobs_retain_the_complete_result_bundle
    steps = @workflow.fetch("jobs").fetch("ios-ui-verification").fetch("steps")
    ui = steps.find { |step| step["id"] == "ui" }
    upload = steps.find { |step| step["uses"].to_s.start_with?("actions/upload-artifact@") }
    refute_nil upload, "A failed UI job must retain its result bundle"
    assert_equal "failure()", upload.fetch("if")
    inputs = upload.fetch("with")
    assert_equal ui.fetch("env").fetch("IOS_TEST_RESULT_BUNDLE_PATH"), inputs.fetch("path")
    assert_equal true, inputs.fetch("include-hidden-files")
    assert_equal "warn", inputs.fetch("if-no-files-found")
    assert_equal 7, inputs.fetch("retention-days")
    assert_includes inputs.fetch("name"), "github.run_id"
    assert_includes inputs.fetch("name"), "github.run_attempt"
  end
  def diagnostic_steps
    steps = @workflow.fetch("jobs").fetch("ios-ui-verification").fetch("steps")
    [steps.find { |step| step["name"] == "Configure UI latency diagnostics" },
      steps.find { |step| step["id"] == "ui" },
      steps.find { |step| step["name"] == "Retain UI latency diagnostics" }]
  end

  def test_ui_diagnostics_default_to_disabled
    inputs = (@workflow["on"] || @workflow.fetch(true)).fetch("workflow_dispatch").fetch("inputs")
    diagnostics = inputs.fetch("collect_ui_diagnostics", {})
    assert_equal "boolean", diagnostics["type"]
    assert_equal false, diagnostics["default"]
  end

  def test_ui_diagnostics_skip_default_and_non_dispatch_runs
    configure, ui, upload = diagnostic_steps
    refute ui.fetch("env").key?("IOS_TEST_DIAGNOSTICS_PATH"), "The test command must not enable collection unconditionally"
    refute_nil configure
    ["pull_request", "merge_group", "workflow_dispatch"].each do |event|
      [nil, false, true].each do |opt_in|
        next if event == "workflow_dispatch" && opt_in == true
        context = {"github.event_name" => event, "inputs.collect_ui_diagnostics" => opt_in}
        refute evaluate(configure.fetch("if"), context), "Unexpected collector for #{event}, opt-in #{opt_in.inspect}"
        refute evaluate(upload.fetch("if"), context), "Unexpected upload for #{event}, opt-in #{opt_in.inspect}"
      end
    end
  end

  def test_ui_diagnostics_collect_and_retain_only_on_opted_in_dispatch
    configure, ui, upload = diagnostic_steps
    refute_nil configure
    refute_nil upload
    context = {"github.event_name" => "workflow_dispatch", "inputs.collect_ui_diagnostics" => true}
    assert evaluate(configure.fetch("if"), context)
    assert evaluate(upload.fetch("if"), context)
    assert_equal true, configure["continue-on-error"], "Diagnostic setup errors must not fail the UI job"
    assert_equal true, upload.fetch("continue-on-error")
    assert_equal 7, upload.fetch("with").fetch("retention-days")
    assert_equal "warn", upload.fetch("with").fetch("if-no-files-found")
    Dir.mktmpdir("ui-diagnostic-workflow") do |directory|
      context["runner.temp"] = directory
      environment_file = File.join(directory, "github-env")
      variables = configure.fetch("env").transform_values do |value|
        value.gsub(/\$\{\{.*?\}\}/) { |expression| evaluate(expression, context).to_s }
      end
      output, status = Open3.capture2e(variables.merge("GITHUB_ENV" => environment_file), "bash", "-c", configure.fetch("run"))
      assert status.success?, output
      exported = File.readlines(environment_file, chomp: true).to_h { |line| line.split("=", 2) }
      expected_path = upload.fetch("with").fetch("path").gsub(/\$\{\{.*?\}\}/) { |expression| evaluate(expression, context).to_s }
      assert_equal expected_path, exported.fetch("IOS_TEST_DIAGNOSTICS_PATH")
      refute ui.fetch("env").key?("IOS_TEST_DIAGNOSTICS_PATH"), "The test command must retain the conditional exported value"
    end
  end

end
