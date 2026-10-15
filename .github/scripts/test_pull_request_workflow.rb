require "minitest/autorun"
require "yaml"
require "open3"
require "tmpdir"
require "fileutils"
require "json"
require "timeout"

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
    source = source.gsub(/(?:github|inputs|runner|needs)\.[a-z_.\-]+/) { |path| context.fetch(path, nil).inspect }
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

  WORKER_JOBS = %w[
    repository-hygiene package-verification ios-verification ios-ui-verification macos-verification
  ].freeze
  WATCHDOG = "cancel-on-failure"
  # Runs only for pull requests, so the queue watchdog never waits for it; it is a worker, not a result job.
  PULL_REQUEST_ONLY_WORKERS = %w[swift-style-linux].freeze

  def watchdog
    @workflow.fetch("jobs").fetch(WATCHDOG)
  end

  def test_only_the_queue_watchdog_may_write_actions_and_it_runs_no_code_of_the_pull_request
    assert_equal({"contents" => "read"}, @workflow.fetch("permissions"))
    jobs = @workflow.fetch("jobs")
    jobs.each do |name, job|
      scopes = job.fetch("permissions", {})
      if name == WATCHDOG
        assert_equal({"actions" => "write"}, scopes, "the watchdog has no other scope, also no contents")
      else
        refute scopes.key?("actions"), "#{name} must not request an actions scope"
        assert_empty scopes.values - %w[read], "#{name} stays read-only"
      end
    end
    # Only inline shell: no checkout, no action, no script of the pull request.
    steps = watchdog.fetch("steps")
    assert_equal 1, steps.length
    assert_empty steps.first.keys - %w[name env run]
    refute_match(%r{\./|scripts/|\.github/|\bbash \S+\.sh|\bsource\b|\bcurl\b}, steps.first.fetch("run"))
    environment = {"GH_TOKEN" => "${{ github.token }}", "GH_REPO" => "${{ github.repository }}"}
    assert_equal environment, steps.first.fetch("env")
    # No result job waits for it, and it is not a required check.
    jobs.each { |name, job| refute_includes Array(job["needs"]), WATCHDOG, name }
    refute_includes REQUIRED_CHECKS, watchdog.fetch("name")
    assert_equal "ubuntu-24.04", watchdog.fetch("runs-on")
    # The longest queue run took 123 minutes. The loop ends before the job limit, which stays below the 180 minute
    # check timeout of the queue.
    limit = watchdog.fetch("timeout-minutes")
    assert_operator limit, :>=, 150
    assert_operator limit, :<=, 180
    assert_operator watchdog.fetch("steps").first.fetch("run")[/deadline=\$\(\(SECONDS \+ (\d+)\)\)/, 1].to_i, :<, limit * 60
    {"merge_group" => true, "pull_request" => false, "workflow_dispatch" => false}.each do |event, expected|
      assert_equal expected, evaluate(watchdog.fetch("if"), {"github.event_name" => event}), event
    end
  end

  def test_the_watchdog_reads_the_jobs_of_its_run_and_cancels_that_run_only
    script = watchdog.fetch("steps").first.fetch("run")
    assert_includes script, %q(gh api "repos/$GH_REPO/actions/runs/$GITHUB_RUN_ID/jobs" --paginate)
    assert_includes script, %q(gh run cancel "$GITHUB_RUN_ID")
    assert_includes script, "while (( SECONDS < deadline )); do"
    assert_equal 1, script.scan("gh run cancel").length
    assert_equal 1, script.scan("gh api").length
    # The jobs that end the watch are the worker jobs of this workflow.
    names = WORKER_JOBS.map { |id| @workflow.fetch("jobs").fetch(id).fetch("name") }
    listed = script[/^workers=\((.*)\)$/, 1].scan(/"([^"]+)"/).flatten
    assert_equal names, listed
    assert_includes script, %(own="#{watchdog.fetch('name')}")
  end

  # Runs the real script of the watchdog with a fake `gh` and no waiting. Each element of `responses` is the answer
  # of one jobs query: an Array of [name, status, conclusion] rows, or :error.
  def run_watchdog(responses, cancel_exit: 0, cancel_message: "")
    script = watchdog.fetch("steps").first.fetch("run")
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "bin")
      Dir.mkdir(bin)
      File.write(File.join(dir, "script.sh"), script)
      responses.each_with_index do |response, index|
        jobs = response == :error ? [] : response.map do |name, status, conclusion|
          {"name" => name, "status" => status, "conclusion" => conclusion.empty? ? nil : conclusion}
        end
        File.write(File.join(dir, "response.#{index}"), JSON.generate({"jobs" => jobs}))
        File.write(File.join(dir, "error.#{index}"), response == :error ? "1" : "0")
      end
      File.write(File.join(bin, "gh"), <<~SH)
        #!/usr/bin/env bash
        if [[ "$1 $2" == "run cancel" ]]; then
          echo "$3" >> "#{dir}/cancelled"
          [[ -z "${FAKE_CANCEL_MESSAGE:-}" ]] || echo "$FAKE_CANCEL_MESSAGE" >&2
          exit "${FAKE_CANCEL_EXIT:-0}"
        fi
        n=$(cat "#{dir}/calls" 2>/dev/null || echo 0)
        echo $((n + 1)) > "#{dir}/calls"
        i=$((n < #{responses.length} ? n : #{responses.length} - 1))
        if [[ "$(cat "#{dir}/error.$i")" == 1 ]]; then echo "HTTP 502" >&2; exit 1; fi
        # The real filter of the script runs on the JSON of the API.
        filter=""
        while [[ $# -gt 0 ]]; do if [[ "$1" == "--jq" ]]; then filter="$2"; fi; shift; done
        jq -r "$filter" "#{dir}/response.$i"
      SH
      # A script that never ends is stopped after 40 waits, so a broken loop fails the test instead of hanging it.
      File.write(File.join(bin, "sleep"), <<~SH)
        #!/usr/bin/env bash
        echo "$1" >> "#{dir}/slept"
        if [[ $(wc -l < "#{dir}/slept") -ge 40 ]]; then kill -9 "$PPID"; fi
      SH
      FileUtils.chmod(0o755, [File.join(bin, "gh"), File.join(bin, "sleep")])
      env = {"PATH" => "#{bin}:#{ENV.fetch('PATH')}", "GH_REPO" => "owner/repo", "GITHUB_RUN_ID" => "4242",
             "GH_TOKEN" => "unused", "FAKE_CANCEL_EXIT" => cancel_exit.to_s,
             "FAKE_CANCEL_MESSAGE" => cancel_message}
      _out, status = Timeout.timeout(20) { Open3.capture2e(env, "bash", File.join(dir, "script.sh")) }
      cancelled = File.exist?(File.join(dir, "cancelled")) ? File.read(File.join(dir, "cancelled")).split : []
      calls = File.exist?(File.join(dir, "calls")) ? File.read(File.join(dir, "calls")).to_i : 0
      @waits = File.exist?(File.join(dir, "slept")) ? File.read(File.join(dir, "slept")).split : []
      [status.exitstatus, cancelled, calls]
    end
  end

  def workers(status:, conclusion: "success")
    WORKER_JOBS.map do |id|
      [@workflow.fetch("jobs").fetch(id).fetch("name"), status, status == "completed" ? conclusion : ""]
    end
  end

  def test_the_watchdog_cancels_on_the_first_failed_job_and_ends_when_the_workers_finish
    own = ["Cancel a queue run after a failure", "in_progress", ""]
    running = workers(status: "in_progress")
    failed_ui = workers(status: "in_progress").tap { |rows| rows[3] = [rows[3][0], "completed", "failure"] }
    # A failure: one cancel of this run, then the job ends.
    status, cancelled, calls = run_watchdog([running + [own], failed_ui + [own]])
    assert_equal [0, ["4242"], 2], [status, cancelled, calls]
    # A failed result job counts as well.
    result = ["Swift package tests", "completed", "failure"]
    assert_equal ["4242"], run_watchdog([running + [own, result]])[1]
    # All workers done without a failure: no cancel.
    status, cancelled, = run_watchdog([running + [own], workers(status: "completed") + [own]])
    assert_equal [0, []], [status, cancelled]
    # Cancelled or skipped jobs are not failures.
    cancelled_rows = workers(status: "completed").tap do |rows|
      rows[1..].each_index { |index| rows[index + 1] = [rows[index + 1][0], "completed", "cancelled"] }
    end + [own]
    assert_equal [0, []], run_watchdog([cancelled_rows]).first(2)
    # The own job never counts, also when it shows a failure.
    own_failed = ["Cancel a queue run after a failure", "completed", "failure"]
    assert_equal [0, []], run_watchdog([workers(status: "completed") + [own_failed]]).first(2)
    # A worker job that is not listed yet keeps the watch going until it appears.
    partial = workers(status: "completed").first(3) + [own]
    status, cancelled, calls = run_watchdog([partial, partial, workers(status: "completed") + [own]])
    assert_equal [0, [], 3], [status, cancelled, calls]
    assert_equal %w[30 30], @waits, "every wait is 30 seconds"
  end

  def test_the_watchdog_survives_api_errors_and_a_failing_cancel
    own = ["Cancel a queue run after a failure", "in_progress", ""]
    failed = workers(status: "completed", conclusion: "failure") + [own]
    status, cancelled, calls = run_watchdog([:error, :error, failed])
    assert_equal [0, ["4242"], 3], [status, cancelled, calls]
    assert_equal ["30", "30"], @waits.first(2), "every wait is 30 seconds"
    # A cancel request that fails ends the job red (the job is not required), also without a second attempt, unless
    # the run is already cancelled or completed.
    status, cancelled, = run_watchdog([failed], cancel_exit: 1, cancel_message: "HTTP 500")
    assert_equal [1, ["4242"]], [status, cancelled]
    status, cancelled, = run_watchdog([failed], cancel_exit: 1, cancel_message: "HTTP 409: Cannot cancel a workflow run that is completed")
    assert_equal [0, ["4242"]], [status, cancelled]
    # A read that keeps failing ends red after 20 attempts, so that nothing silently watches nothing.
    status, cancelled, calls = run_watchdog([:error])
    assert_equal [1, [], 20], [status, cancelled, calls]
    # A hygiene job that ended without success (a timeout is a cancelled job) cancels the run too; a manual cancel
    # of the whole run finds an already cancelled run and ends without an error.
    hygiene_timeout = workers(status: "in_progress").tap { |rows| rows[0] = [rows[0][0], "completed", "cancelled"] }
    assert_equal ["4242"], run_watchdog([hygiene_timeout + [own]])[1]
  end

  def test_every_result_job_runs_also_when_a_worker_job_is_cancelled
    results = @workflow.fetch("jobs").reject do |id, _|
      WORKER_JOBS.include?(id) || PULL_REQUEST_ONLY_WORKERS.include?(id) || id == WATCHDOG
    end
    PULL_REQUEST_ONLY_WORKERS.each do |id|
      refute evaluate(@workflow.fetch("jobs").fetch(id).fetch("if"), {"github.event_name" => "merge_group"}), id
    end
    refute_empty results
    results.each do |id, job|
      assert_includes job.fetch("if").to_s, "always()", "#{id}: a cancelled run must still produce a failing check"
      refute_empty job.fetch("needs"), id
    end
  end

  def test_a_pull_request_is_checked_for_style_on_linux_and_every_other_event_on_the_macos_runner
    jobs = @workflow.fetch("jobs")
    linux = jobs.fetch("swift-style-linux")
    macos = jobs.fetch("package-verification")
    result = jobs.fetch("code-quality")
    assert_equal "ubuntu-24.04", linux.fetch("runs-on")
    assert_equal "Swift style", result.fetch("name")
    assert_includes REQUIRED_CHECKS, result.fetch("name")
    refute_includes REQUIRED_CHECKS, linux.fetch("name")
    {"pull_request" => [true, false], "merge_group" => [false, true], "workflow_dispatch" => [false, true]}
      .each do |event, (on_linux, on_macos)|
        context = {"github.event_name" => event}
        assert_equal on_linux, evaluate(linux.fetch("if"), context), "Linux job, #{event}"
        assert_equal on_macos, macos.fetch("if", "${{ true }}").then { |condition| evaluate(condition, context) }, "macOS job, #{event}"
      end
    assert_equal %w[package-verification swift-style-linux], result.fetch("needs").sort
    assert_equal "${{ always() }}", result.fetch("if")
    # The result job takes the verdict of the job that ran for the event, and nothing else.
    step = result.fetch("steps").first
    assert_equal({"EVENT" => "${{ github.event_name }}", "LINUX_RESULT" => "${{ needs.swift-style-linux.outputs.style }}",
                  "MACOS_RESULT" => "${{ needs.package-verification.outputs.style }}"}, step.fetch("env"))
    verdicts = ["", "success", "failure", "skipped"]
    {"pull_request" => "LINUX_RESULT", "merge_group" => "MACOS_RESULT", "workflow_dispatch" => "MACOS_RESULT"}
      .each do |event, decisive|
        verdicts.product(verdicts).each do |linux_verdict, macos_verdict|
          env = {"EVENT" => event, "LINUX_RESULT" => linux_verdict, "MACOS_RESULT" => macos_verdict}
          _out, status = Open3.capture2e(env, "bash", "-c", step.fetch("run"))
          expected = env.fetch(decisive) == "success"
          assert_equal expected, status.success?, "#{event}: Linux #{linux_verdict.inspect}, macOS #{macos_verdict.inspect}"
        end
      end
    [linux, macos].each do |job|
      style = job.fetch("steps").find { |step| step["id"] == "style" }
      assert_equal "bash scripts/verify-swift-style.sh", style.fetch("run")
      assert_equal "${{ steps.style.outcome }}", job.fetch("outputs").fetch("style")
    end
    # The pinned tools: a hash for every download, and the SwiftLint version of the macOS action.
    install = linux.fetch("steps").find { |step| step["name"] == "Install the Swift toolchain and SwiftLint" }
    env = install.fetch("env")
    assert_match(/\A\h{64}\z/, env.fetch("SWIFT_SHA256"))
    assert_match(/\A\h{64}\z/, env.fetch("SWIFTLINT_SHA256"))
    script = install.fetch("run")
    # Each download is checked by a hash that fails the step, before anything is unpacked, over https only.
    checks = script.lines.select { |line| line.include?("sha256sum") }
    assert_equal 2, checks.length
    checks.each { |line| assert_match(/\A\s*echo "\$\{?\w+\}?  \$RUNNER_TEMP\/\S+" \| sha256sum --check\n?\z/, line) }
    assert script.index("sha256sum").to_i < script.index("tar -xzf")
    assert script.index("sha256sum", script.index("swiftlint.zip\" ")) < script.index("unzip")
    assert_match(/\Aset -euo pipefail/, script)
    assert_equal 2, script.scan("--proto '=https' --proto-redir '=https'").length
    assert_equal 2, script.scan("--max-time").length
    assert_equal 2, script.scan("--retry 3").length
    refute_match(/latest/i, script)
    action = YAML.load_file(File.join(WORKFLOWS, "../actions/install-swiftlint/action.yml"))
    assert_equal action.fetch("runs").fetch("steps").first.fetch("env").fetch("SWIFTLINT_VERSION"), env.fetch("SWIFTLINT_VERSION")
    style = linux.fetch("steps").find { |step| step["id"] == "style" }
    assert_equal "${{ runner.temp }}/swift/usr/lib", style.fetch("env").fetch("LINUX_SOURCEKIT_LIB_PATH")
    refute_nil style.fetch("env").fetch("SWIFT_FORMAT_EXECUTABLE")
    refute_nil style.fetch("env").fetch("SWIFTLINT_EXECUTABLE")
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
    # The style of a pull request runs on Linux (swift-style-linux); the macOS job runs it with the tests in the queue.
    package = jobs.fetch("package-verification")
    refute evaluate(package.fetch("if"), {"github.event_name" => "pull_request"})
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
    # A queue run saves nothing: its cache would belong to its own temporary branch, which no other run reads.
    package = @workflow.fetch("jobs").fetch("package-verification").fetch("steps")
      .find { |step| step["uses"] == "./.github/actions/prepare-apple-build" }
    [ios, package].each do |step|
      saves = step.fetch("with").fetch("save-cache")
      {"merge_group" => false, "workflow_dispatch" => true}.each do |event, expected|
        assert_equal expected, evaluate(saves, {"github.event_name" => event}), "#{event}: #{saves}"
      end
    end
    assert_includes ios.fetch("with").fetch("measure-cache"), "inputs.measure_cache"
    action = YAML.load_file(File.join(WORKFLOWS, "../actions/prepare-apple-build/action.yml"))
    ["Save resolved SwiftPM dependencies", "Save resolved Xcode dependencies"].each do |name|
      save = action.fetch("runs").fetch("steps").find { |step| step["name"] == name }
      assert_includes save.fetch("if"), "inputs.save-cache != 'false'", name
    end
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

  def test_the_ui_job_retries_only_a_runner_bootstrap_failure_and_keeps_the_gate_exact
    job = @workflow.fetch("jobs").fetch("ios-ui-verification")
    steps = job.fetch("steps")
    ui = steps.find { |step| step["id"] == "ui" }
    wrapper = "bash .github/scripts/run_ui_tests_with_retry.sh"
    assert_equal "#{wrapper} bash ./scripts/verify-ios-app-tests.sh ui", ui.fetch("run")
    %w[continue-on-error shell working-directory].each { |key| refute ui.key?(key), "The UI step must not set #{key}" }
    [@workflow["env"], job["env"], ui["env"]].compact.each do |env|
      refute env.key?("UI_TEST_MAX_RETRIES"), "The workflow keeps the retry count of the script"
    end
    assert_equal "${{ steps.ui.outcome }}", job.fetch("outputs").fetch("ui")
    # The wrapper keeps the first attempt next to this bundle, under the name that the upload step collects.
    assert_equal "${{ runner.temp }}/ios-ui.xcresult", ui.fetch("env").fetch("IOS_TEST_RESULT_BUNDLE_PATH")
    assert_equal 90, job.fetch("timeout-minutes")
    # The runner state is informational: it never decides the result, and it runs at the start and at the end.
    start = steps.find { |step| step["name"] == "Record the runner state at the start" }
    finish = steps.find { |step| step["name"] == "Record the runner state at the end" }
    assert_equal "bash .github/scripts/runner_state.sh start", start.fetch("run")
    assert_equal "bash .github/scripts/runner_state.sh end", finish.fetch("run")
    assert_equal "${{ !cancelled() }}", start.fetch("if")
    assert_equal "always()", finish.fetch("if")
    [start, finish].each do |step|
      assert_equal true, step.fetch("continue-on-error")
      assert_equal 2, step.fetch("timeout-minutes")
    end
    prepare = steps.index { |step| step["uses"] == "./.github/actions/prepare-apple-build" }
    assert_operator steps.index(start), :<, prepare
    assert_operator steps.index(finish), :>, steps.index(ui)
    # The first attempt's bundle and log are kept when a retry happened, even if the second attempt passes.
    failed = steps.find { |step| step["name"] == "Retain failed UI test results" }
    kept = steps.find { |step| step["name"] == "Retain the result of the first attempt after a retry" }
    assert_equal "${{ always() && steps.ui.outputs.retried == 'true' }}", kept.fetch("if")
    assert_equal failed.fetch("uses"), kept.fetch("uses")
    # A failed upload of the first attempt must not turn a passing retry red.
    assert_equal true, kept.fetch("continue-on-error")
    assert_includes kept.fetch("with").fetch("name"), "github.run_id"
    assert_includes kept.fetch("with").fetch("name"), "github.run_attempt"
    assert_includes kept.fetch("with").fetch("path"), "ios-ui-attempt1.xcresult"
    assert_includes kept.fetch("with").fetch("path"), "ios-ui-attempt1.log"
    # The bash test of the wrapper runs in the hygiene job.
    hygiene_steps = @workflow.fetch("jobs").fetch("repository-hygiene").fetch("steps")
    hygiene = hygiene_steps.find { |step| step["name"] == "Test GitHub automation" }
    assert_includes hygiene.fetch("run"), "bash .github/scripts/test_run_ui_tests_with_retry.sh"
  end

  def diagnostic_steps
    steps = @workflow.fetch("jobs").fetch("ios-ui-verification").fetch("steps")
    [steps.find { |step| step["name"] == "Configure UI latency diagnostics" },
      steps.find { |step| step["id"] == "ui" },
      steps.find { |step| step["name"] == "Retain UI latency diagnostics" }]
  end

  # A deliberate, narrow exception to "do not search source files in tests": this CI contract finds the darwin-only
  # Python tests, so a new one cannot skip silently on Ubuntu. It reads decorator statements only, also when a
  # decorator is split over lines; parentheses inside its strings would confuse the line counting.
  # skipUnless(platform is darwin) and skipIf(platform is not darwin) mean "only on macOS"; skipIf(platform is darwin)
  # means "not on macOS" and needs no macOS step.
  def darwin_only_guard?(statement)
    unless_darwin = statement.match?(/skipUnless/) && statement.match?(/(==\s*|startswith\()["']darwin/i)
    if_not_darwin = statement.match?(/skipIf/) && statement.match?(/!=\s*["']darwin/i)
    unless_darwin || if_not_darwin
  end

  def darwin_guards(root)
    Dir[File.join(root, ".github/scripts/test_*.py"), File.join(root, "scripts/tests/test_*.py")].flat_map do |path|
      lines = File.readlines(path, encoding: "UTF-8")
      script = path.delete_prefix("#{root}/")
      guards = []
      index = 0
      while index < lines.length
        if lines[index] =~ /\A\s*@.*skip/i
          start = index
          statement = lines[index].dup
          depth = statement.count("(") - statement.count(")")
          while depth > 0 && index + 1 < lines.length
            index += 1
            statement << lines[index]
            depth += lines[index].count("(") - lines[index].count(")")
          end
          if darwin_only_guard?(statement)
            target = lines[(index + 1)..].find { |candidate| candidate =~ /\A\s*(def|class) \w+/ }
            flunk "#{script}:#{start + 1}: a darwin skip guard is followed by no class or method" if target.nil?
            kind, symbol = target.match(/\A\s*(def|class) (\w+)/).captures
            guards << [script, start + 1, kind, symbol]
          end
        end
        index += 1
      end
      guards
    end
  end

  def test_darwin_only_script_tests_run_in_the_macos_job_and_the_queue_requires_them
    jobs = @workflow.fetch("jobs")
    macos = jobs.fetch("macos-verification")
    steps = macos.fetch("steps")
    probes = steps.find { |step| step["id"] == "upgrade-probes" }
    refute_nil probes, "The macOS job must run the tests that skip themselves on other systems"
    # A darwin-only test class or method skips itself on Ubuntu, so only this macOS step can run it.
    root = File.expand_path("../..", __dir__)
    commands = probes.fetch("run").lines.map(&:strip)
    assert_includes commands, "set -euo pipefail"
    assert_empty commands.grep(/\|\||;|&|#/), "A probe command must not mask its exit status or run in the background"
    assert commands.drop(1).all? { |command| command.match?(%r{\Apython3 (\.github/scripts|scripts/tests)/test_\w+\.py\b}) },
      "The probe step may contain only the shell option line and the Python test commands"
    guards = darwin_guards(root)
    assert_operator guards.length, :>=, 2
    guards.each do |script, line, kind, symbol|
      pattern = if kind == "class"
        /\Apython3 #{Regexp.escape(script)}\z/ # A guarded class runs as part of its whole file.
      else
        /\Apython3 #{Regexp.escape(script)} .*\b#{Regexp.escape(symbol)}\b/
      end
      assert commands.any? { |command| command.match?(pattern) },
        "#{script}:#{line}: #{kind} #{symbol} is darwin-only but the macOS job does not run it"
    end
    checkout = steps.find { |step| step["uses"].to_s.start_with?("actions/checkout@") }
    refute_nil checkout, "The macOS job must check out the source"
    assert_equal 0, checkout.fetch("with").fetch("fetch-depth"), "The Metal test reads pinned releases by tag"
    python = steps.find { |step| step["id"] == "python" }
    refute_nil python, "The macOS job must set up Python before the probes"
    # The exact conditions: a cancelled run reports nothing, and no earlier failure may hide the probe result.
    assert_equal "${{ !cancelled() }}", python.fetch("if")
    assert_equal "${{ !cancelled() && steps.python.outcome == 'success' }}", probes.fetch("if")
    # The same pinned action and version as the upgrade gate that runs on the same image.
    upgrade_python = YAML.load_file(File.join(WORKFLOWS, "testflight-internal.yml")).fetch("jobs").fetch("upgrade")
      .fetch("steps").find { |step| step["id"] == "python" }
    assert_match(/\Aactions\/setup-python@[0-9a-f]{40}\z/, python.fetch("uses"))
    assert_equal upgrade_python.fetch("uses"), python.fetch("uses")
    assert_equal upgrade_python.fetch("with").fetch("python-version"), python.fetch("with").fetch("python-version")
    assert_operator steps.index(python), :<, steps.index(probes)
    assert_equal "${{ steps.upgrade-probes.outcome }}", macos.fetch("outputs").fetch("upgrade_probes")
    gate_job = jobs.fetch("macos-app-shell")
    assert_equal "macOS app shell", gate_job.fetch("name"), "The gate must stay the required check of that name"
    gate = gate_job.fetch("steps").find { |step| step.fetch("env", {}).key?("RESULT") &&
      step.fetch("env").fetch("RESULT").include?("upgrade_probes") }
    refute_nil gate, "The macOS gate must require the probe result"
    assert_equal "${{ needs.macos-verification.outputs.upgrade_probes }}", gate.fetch("env").fetch("RESULT")
    assert_equal 'test "$RESULT" = success', gate.fetch("run")
    assert_equal "${{ always() }}", gate.fetch("if"), "The probe result must report even when the app shell check fails"
    assert_includes gate_job.fetch("needs"), "macos-verification"
    # Without always(), a failing macOS job would skip the gate and the required check would never be evaluated.
    assert_equal "${{ always() && github.event_name != 'pull_request' }}", gate_job.fetch("if")
    # A shell or directory template could run nothing and still report success.
    [["probe step", probes], *gate_job.fetch("steps").map { |step| ["macOS gate step #{step["name"]}", step] }].each do |name, item|
      %w[shell working-directory].each { |key| refute item.key?(key), "The #{name} must not set #{key}" }
    end
    [["workflow", @workflow], ["macOS job", macos], ["macOS gate job", gate_job]].each do |name, item|
      refute item.key?("defaults"), "The #{name} must not set default run options"
    end
    # continue-on-error would turn a failed step into an "outcome" of success for the gate.
    { "macOS job" => macos, "Python step" => python, "probe step" => probes, "macOS gate job" => gate_job }
      .merge(gate_job.fetch("steps").to_h { |step| ["macOS gate step #{step["name"]}", step] }).each do |name, item|
      refute item.key?("continue-on-error"), "The #{name} must not set continue-on-error"
    end
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
