#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "yaml"
require "tmpdir"
require "fileutils"
require_relative "test_release_identity"

class ReleaseUpgradeWorkflowTest < Minitest::Test
  def setup
    @workflow = YAML.load_file(File.expand_path("../workflows/testflight-internal.yml", __dir__))
    @jobs = @workflow.fetch("jobs")
  end

  def test_upgrade_script_behavior
    %w[test_release_upgrade.py test_keychain_entitlements.py test_upgrade_journey.py test_upgrade_metadata.py test_upgrade_metal.py test_upgrade_payload_pins.py].each do |script|
      assert system("python3", File.expand_path(script, __dir__)), "#{script} failed"
    end
  end

  def test_both_platform_archives_finish_before_the_upgrade_gate_and_upload
    assert_includes Array(@jobs.fetch("upgrade").fetch("needs")), "build"
    assert_includes Array(@jobs.fetch("upload").fetch("needs")), "upgrade"
    assert_includes Array(@jobs.fetch("upload").fetch("needs")), "build"
    refute @jobs.fetch("upgrade").key?("if"), "Stable releases and betas both require the gate"
    refute @jobs.fetch("upload").key?("if"), "Upload must use the default successful-needs barrier"
    platforms = IO.popen(["python3", "-c", "import sys; sys.path.insert(0, sys.argv[1]); " \
      "import release_upgrade as r; print(' '.join(sorted({k[0] for k in r.CONFIGURATIONS})))", File.expand_path(__dir__)], &:read).split
    assert_equal %w[iOS macOS], platforms.sort
    build = @jobs.fetch("build").fetch("steps").map { |step| step["run"].to_s }.join("\n")
    assert_includes build, "xcodebuild archive"
    refute_includes build, "altool --upload-package"
    upload = @jobs.fetch("upload").fetch("steps").map { |step| step["run"].to_s }.join("\n")
    assert_includes upload, "altool --upload-package"
    refute_includes upload, "xcodebuild archive"
  end

  # The jobs of the upgrade gate come from the one point list of the journey and the selected sources; a new point
  # or source needs no workflow edit. The generator is tested in test_release_upgrade.py; this checks the wiring.
  def test_the_jobs_of_the_upgrade_gate_are_generated_from_the_point_list_and_the_sources
    journey = File.expand_path("../../scripts/upgrade-test/run_journey.py", __dir__)
    points = IO.popen(["python3", journey, "--list-points"], &:read).split
    refute_empty points
    assert_equal points.uniq, points
    matrix = @jobs.fetch("upgrade").dig("strategy", "matrix")
    assert_includes @jobs.fetch("upgrade").fetch("name"), "${{ matrix.os }}"
    assert_includes @jobs.fetch("upgrade").fetch("name"), "${{ matrix.device }}"
    assert_equal "${{ fromJSON(needs.prepare.outputs.upgrade_matrix) }}", matrix
    assert_equal "${{ steps.upgrade-plan.outputs.upgrade_matrix }}", @jobs.fetch("prepare").fetch("outputs").fetch("upgrade_matrix")
    plan = @jobs.fetch("prepare").fetch("steps").find { |step| step["id"] == "upgrade-plan" }
    refute_nil plan
    [points, points + (1..5).map { |index| "extra.#{index}" }].each do |listed|
      generated = IO.popen(["python3", "-c", "import json, sys; sys.path.insert(0, sys.argv[1]); " \
        "import release_upgrade as r, test_release_upgrade as t; print(json.dumps(r.upgrade_matrix(['a', 'b', 'c'], sys.argv[2].split(), t.synthetic_capacity())))",
                            File.expand_path(__dir__), listed.join(" ")], &:read)
      shards = JSON.parse(generated).fetch("include")
      shards.group_by { |shard| [shard.fetch("platform"), shard.fetch("os"), shard.fetch("device")] }.each do |configuration, group|
        covered = group.flat_map { |shard| shard.fetch("points").split }
        assert_equal listed.sort, covered.sort, "#{configuration} shards must cover every point exactly once"
      end
      assert_equal shards.length, shards.map { |shard| [shard.fetch("platform"), shard.fetch("os"), shard.fetch("device"), shard.fetch("shard")] }.uniq.length
    end
    run = @jobs.fetch("upgrade").fetch("steps").find { |step| step["name"] == "Test installed upgrades" }
    assert_equal "${{ matrix.points }}", run.fetch("env").fetch("UPGRADE_POINTS")
    assert_equal "${{ matrix.os }}", run.fetch("env")["UPGRADE_OS"]
    assert_equal "${{ matrix.device }}", run.fetch("env")["UPGRADE_DEVICE"]
    assert_equal "${{ matrix.runtime_id }}", run.fetch("env")["UPGRADE_RUNTIME_ID"]
    assert_equal "${{ matrix.runtime_version }}", run.fetch("env")["UPGRADE_RUNTIME_VERSION"]
    assert_equal "${{ matrix.runtime_build }}", run.fetch("env")["UPGRADE_RUNTIME_BUILD"]
    assert_includes run.fetch("run"), '--points "${points[@]}"'
    artifact = @jobs.fetch("upgrade").fetch("steps").find { |step| step["name"] == "Retain upgrade evidence" }
    assert_includes artifact.dig("with", "name"), "${{ matrix.shard }}"
    assert_includes artifact.dig("with", "name"), "${{ matrix.os }}"
    assert_includes artifact.dig("with", "name"), "${{ matrix.device }}"
  end

  def test_ios_26_runtime_is_provisioned_before_the_journey
    steps = @jobs.fetch("upgrade").fetch("steps")
    provision = steps.find { |step| step["id"] == "ios26-runtime" }
    refute_nil provision, "iOS 26 needs an explicit runtime provisioning step"
    assert_equal "needs.prepare.outputs.upgrade_overridden != 'true' && matrix.platform == 'iOS' && matrix.os == '26'", provision.fetch("if")
    assert_equal "${{ matrix.runtime_version }}", provision.fetch("env").fetch("UPGRADE_RUNTIME_VERSION")
    assert_equal "${{ matrix.runtime_build }}", provision.fetch("env").fetch("UPGRADE_RUNTIME_BUILD")
    assert_includes provision.fetch("run"), '-buildVersion "$UPGRADE_RUNTIME_VERSION"'
    assert_includes provision.fetch("run"), 'run_journey.py --check-runtime'
    assert_operator steps.index(provision), :<, steps.index(steps.find { |step| step["id"] == "journey" })
  end

  def test_the_optional_provisioning_override_reaches_the_planner_from_the_repository_variable
    plan = @jobs.fetch("prepare").fetch("steps").find { |step| step["id"] == "upgrade-plan" }
    assert_equal "${{ vars.RELEASE_UPGRADE_PROVISIONING }}", plan.fetch("env").fetch("UPGRADE_PROVISIONING")
  end

  def nightly_gate_step
    @jobs.fetch("prepare").fetch("steps").find { |step| step["id"] == "nightly-gate" }
  end

  def test_the_nightly_gate_runs_in_prepare_between_the_upgrade_plan_and_the_tag_checkout_with_the_actions_scope
    steps = @jobs.fetch("prepare").fetch("steps")
    gate = nightly_gate_step
    refute_nil gate
    ids = steps.map { |step| step["id"] }
    assert_operator ids.index("upgrade-plan"), :<, steps.index(gate)
    checkout = steps.index { |step| step["uses"].to_s.start_with?("actions/checkout") && step.dig("with", "ref").to_s.include?("steps.release.outputs.tag") }
    assert_operator steps.index(gate), :<, checkout, "the trusted script runs before the release tag is checked out"
    assert_equal({"contents" => "read", "actions" => "read"}, @jobs.fetch("prepare").fetch("permissions"))
    @jobs.each do |name, job|
      refute job.fetch("permissions", {}).key?("actions"), "#{name} needs no actions scope" unless %w[prepare report-upgrade-failure].include?(name)
    end
    refute gate.key?("continue-on-error"), "a refusal must fail the job"
    assert_equal "${{ steps.revision.outputs.commit_sha }}", gate.fetch("env").fetch("RELEASE_COMMIT")
    assert_equal "${{ steps.upgrade-plan.outputs.upgrade_overridden }}", gate.fetch("env").fetch("OVERRIDDEN")
    assert_equal "${{ inputs.upgrade_override_reason }}", gate.fetch("env").fetch("OVERRIDE_REASON")
  end

  # The step runs the real script with a fake `gh` that finds no run: the commit reaches the query, a refusal fails the
  # step, and the override skips the read.
  def test_the_nightly_gate_step_refuses_a_commit_without_a_run_and_the_override_skips_the_read
    root = File.expand_path("../..", __dir__)
    commit = "0123456789abcdef0123456789abcdef01234567"
    Dir.mktmpdir do |dir|
      gh = File.join(dir, "gh")
      File.write(gh, "#!/usr/bin/env bash\necho \"$*\" >> \"$GH_LOG\"\necho '[{\"total_count\":0,\"workflow_runs\":[]}]'\n")
      File.chmod(0o755, gh)
      log = File.join(dir, "calls.log")
      env = {"PATH" => "#{dir}:#{ENV.fetch("PATH")}", "GH_LOG" => log, "GITHUB_STEP_SUMMARY" => File.join(dir, "summary"),
             "GITHUB_REPOSITORY" => "example/repository", "RELEASE_COMMIT" => commit, "RELEASE_TAG" => "v9.9.9",
             "OVERRIDE_REASON" => "Hosted runners are down"}
      run = lambda do |overridden|
        File.write(log, "")
        ok = system(env.merge("OVERRIDDEN" => overridden), "bash", "-c", nightly_gate_step.fetch("run"), chdir: root, out: File::NULL, err: File::NULL)
        [ok, File.read(log)]
      end
      ok, calls = run.call("false")
      refute ok, "a commit without a nightly run must fail the step"
      assert_includes calls, "head_sha=#{commit}"
      ok, calls = run.call("true")
      assert ok, "the deliberate override skips the gate"
      assert_equal "", calls
      assert_includes File.read(File.join(dir, "summary")), "Hosted runners are down"
      # The planner accepts a reason or a tag that starts with a dash (argparse takes such a value with a space as a value
      # anyway, so the case without a space is the one that counts); the gate must take it as a value, not an option.
      env = env.merge("OVERRIDE_REASON" => "-urgent", "RELEASE_TAG" => "-v9")
      ok, calls = run.call("true")
      assert ok, "a reason that starts with a dash is a value"
      assert_equal "", calls
      assert_includes File.read(File.join(dir, "summary")), "-urgent"
    end
  end

  def test_the_nightly_gate_step_stops_after_the_time_budget_of_its_script_and_before_the_job_timeout
    step = nightly_gate_step
    minutes = IO.popen(["python3", "-c", "import sys; sys.path.insert(0, sys.argv[1]); import release_nightly_gate as g; " \
      "print(g.STEP_MINUTES, g.BUDGET_SECONDS)", File.expand_path(__dir__)], &:read).split.map(&:to_i)
    assert_equal minutes[0], step.fetch("timeout-minutes"), "the step stops at the minutes that the script knows"
    assert_operator minutes[1] + 30, :<=, step.fetch("timeout-minutes") * 60
    assert_operator step.fetch("timeout-minutes"), :<, @jobs.fetch("prepare").fetch("timeout-minutes")
  end

  def test_the_override_input_says_that_it_skips_the_nightly_gate_too
    inputs = (@workflow["on"] || @workflow.fetch(true)).fetch("workflow_dispatch").fetch("inputs")
    assert_includes inputs.fetch("upgrade_override_tag").fetch("description"), "nightly UI gate"
  end

  def report_step
    @jobs.fetch("report-upgrade-failure").fetch("steps").find { |step| step["name"] == "Report the cause of the failed upgrade jobs" }
  end

  def test_a_failed_upgrade_gate_is_classified_in_a_job_that_changes_no_result
    job = @jobs.fetch("report-upgrade-failure")
    assert_equal %w[prepare upgrade], Array(job.fetch("needs"))
    assert_includes job.fetch("if"), "always()"
    assert_includes job.fetch("if"), "needs.upgrade.result == 'failure'"
    refute_includes job.fetch("if"), "cancelled"
    assert_equal({"contents" => "read", "actions" => "read", "checks" => "read"}, job.fetch("permissions"))
    @jobs.each do |name, other|
      refute_includes Array(other["needs"]), "report-upgrade-failure", "#{name} must not wait for the report"
    end
    refute job.key?("environment"), "the report needs no release secret"
    upgrade_timeout = @jobs.fetch("upgrade").fetch("timeout-minutes")
    limit = IO.popen(["python3", "-c", "import sys; sys.path.insert(0, sys.argv[1]); import release_upgrade as r; print(r.JOB_TIMEOUT_MINUTES)",
                      File.expand_path(__dir__)], &:read).to_i
    assert_equal upgrade_timeout, limit, "the classifier must know the timeout of the upgrade job"
    assert_equal "${{ needs.prepare.outputs.automation_sha }}", job.fetch("steps").first.dig("with", "ref")
  end

  # The step runs the real classifier on the recorded jobs of a failed release run through a fake `gh`.
  def test_the_report_step_names_the_failed_steps_of_the_recorded_run_and_reads_the_current_attempt
    root = File.expand_path("../..", __dir__)
    recorded = File.read(File.join(__dir__, "fixtures", "upgrade_jobs_run_41064872152.json"))
    Dir.mktmpdir do |dir|
      gh = File.join(dir, "gh")
      File.write(gh, "#!/usr/bin/env bash\necho \"$*\" >> \"$GH_LOG\"\ncat \"$GH_ANSWER\"\n")
      File.chmod(0o755, gh)
      File.write(File.join(dir, "answer.json"), "[#{recorded}]")
      env = {"PATH" => "#{dir}:#{ENV.fetch("PATH")}", "GH_LOG" => File.join(dir, "calls.log"), "GH_ANSWER" => File.join(dir, "answer.json"),
             "GITHUB_STEP_SUMMARY" => File.join(dir, "summary"), "GITHUB_OUTPUT" => File.join(dir, "output"),
             "GITHUB_REPOSITORY" => "example/repository", "GITHUB_RUN_ID" => "4242", "GITHUB_RUN_ATTEMPT" => "2", "RUNNER_TEMP" => dir}
      assert system(env, "bash", "-c", report_step.fetch("run"), chdir: root, out: File::NULL, err: File::NULL)
      assert_includes File.read(File.join(dir, "calls.log")), "actions/runs/4242/attempts/2/jobs"
      assert_includes File.read(File.join(dir, "summary")), "a step failed in this job"
      assert_includes File.read(File.join(dir, "summary")), "attempt 2"
      assert_includes File.read(File.join(dir, "output")), "retry=false"
    end
  end

  # A fake `gh` for the classifier steps. It logs every call and answers by the last argument: the annotations of a check run
  # from notes-<id>.json (and fails when there is no such file), the current attempt of a run, and the jobs of a run.
  FAKE_GH = <<~'BASH'
    #!/usr/bin/env bash
    echo "$*" >> "$GH_LOG"
    for last; do :; done
    case "$last" in
      *check-runs/*/annotations*)
        id=${last#*check-runs/}; id=${id%%/*}
        if [ -f "$GH_DIR/notes-$id.json" ]; then cat "$GH_DIR/notes-$id.json"; else exit 1; fi ;;
      .run_attempt) echo "${GH_CURRENT_ATTEMPT:-1}" ;;
      *) if [ "$1" = api ]; then cat "$GH_DIR/jobs.json"; fi ;;
    esac
    exit 0
  BASH

  def write_fake_gh(dir, jobs: [], annotations: {})
    gh = File.join(dir, "gh")
    File.write(gh, FAKE_GH)
    File.chmod(0o755, gh)
    File.write(File.join(dir, "jobs.json"), JSON.generate([{"jobs" => jobs}]))
    annotations.each { |id, notes| File.write(File.join(dir, "notes-#{id}.json"), JSON.generate([notes])) }
    {"PATH" => "#{dir}:#{ENV.fetch("PATH")}", "GH_LOG" => File.join(dir, "calls.log"), "GH_DIR" => dir,
     "GITHUB_STEP_SUMMARY" => File.join(dir, "summary"), "GITHUB_OUTPUT" => File.join(dir, "output"),
     "GITHUB_REPOSITORY" => "example/repository", "RUNNER_TEMP" => dir}
  end

  def recorded_annotations
    JSON.parse(File.read(File.join(__dir__, "fixtures", "upgrade_annotations_runs_38193953552_38181793360.json")))
  end

  # The real job records of a lost runner and of a full runner disk both end without a failed step; only the annotation tells them apart.
  def test_the_report_step_reads_the_annotations_of_a_job_without_a_failed_step
    root = File.expand_path("../..", __dir__)
    {"lost_runner" => ["retry=true", "lost its runner"], "disk_full" => ["retry=false", "runner disk"]}.each do |key, (flag, text)|
      record = recorded_annotations.fetch(key)
      id = record.dig("job", "id")
      Dir.mktmpdir do |dir|
        env = write_fake_gh(dir, jobs: [record.fetch("job")], annotations: {id => record.fetch("annotations")})
        env = env.merge("GITHUB_RUN_ID" => "4242", "GITHUB_RUN_ATTEMPT" => "1")
        assert system(env, "bash", "-c", report_step.fetch("run"), chdir: root, out: File::NULL, err: File::NULL), key
        assert_includes File.read(File.join(dir, "calls.log")), "repos/example/repository/check-runs/#{id}/annotations"
        assert_includes File.read(File.join(dir, "output")), flag, key
        assert_includes File.read(File.join(dir, "summary")), text, key
      end
    end
  end

  def test_the_report_step_does_not_retry_when_the_annotations_cannot_be_read
    root = File.expand_path("../..", __dir__)
    record = recorded_annotations.fetch("lost_runner")
    Dir.mktmpdir do |dir|
      env = write_fake_gh(dir, jobs: [record.fetch("job")]).merge("GITHUB_RUN_ID" => "4242", "GITHUB_RUN_ATTEMPT" => "1")
      assert system(env, "bash", "-c", report_step.fetch("run"), chdir: root, out: File::NULL, err: File::NULL)
      assert_includes File.read(File.join(dir, "output")), "retry=false"
      assert_includes File.read(File.join(dir, "summary")), "do not name a lost runner"
    end
  end

  def retry_workflow
    YAML.load_file(File.expand_path("../workflows/upgrade-retry.yml", __dir__))
  end

  def retry_step(job, name)
    retry_workflow.dig("jobs", job, "steps")&.find { |step| step["name"] == name }
  end

  # The retry is a separate workflow because a run can be re-run only after it has completed (#1016).
  def test_the_retry_runs_after_the_release_workflow_ends_and_only_the_job_that_reruns_holds_the_write_scope
    workflow = retry_workflow
    trigger = workflow["on"] || workflow[true]
    assert_equal [@workflow.fetch("name")], trigger.dig("workflow_run", "workflows")
    assert_equal ["completed"], trigger.dig("workflow_run", "types")
    assert_equal({}, workflow["permissions"], "no scope at workflow level")
    assert_equal %w[classify rerun], workflow.fetch("jobs").keys
    classify = workflow.dig("jobs", "classify")
    rerun = workflow.dig("jobs", "rerun")
    assert_equal({"contents" => "read", "actions" => "read", "checks" => "read"}, classify["permissions"])
    assert_equal({"actions" => "write"}, rerun["permissions"], "the write scope and nothing else")
    condition = classify["if"].to_s
    assert_includes condition, "github.event.workflow_run.conclusion == 'failure'"
    assert_includes condition, "github.event.workflow_run.run_attempt == 1"
    assert_includes condition, "github.event.workflow_run.head_repository.full_name == github.repository"
    assert_includes condition, "github.event.workflow_run.path == '.github/workflows/testflight-internal.yml'"
    assert_equal "classify", rerun["needs"]
    assert_equal "needs.classify.outputs.retry == 'true'", rerun["if"]
    assert_equal "${{ steps.classify.outputs.retry }}", classify.dig("outputs", "retry")
    assert_equal 1, rerun["steps"].length
    rerun["steps"].each { |step| refute step.key?("uses"), "the job with the write scope checks out nothing and uses no action" }
    checkout = classify["steps"].find { |step| step["uses"].to_s.start_with?("actions/checkout") }
    refute_nil checkout
    assert_equal({"persist-credentials" => false}, checkout["with"], "the default branch, and the token is not kept")
    @workflow.fetch("jobs").each_value { |other| refute_equal "write", other.fetch("permissions", {})["actions"] }
  end

  # The data of the triggering run reaches the steps only as the run id and the attempt, never inside a script.
  def test_the_retry_steps_take_nothing_from_the_triggering_run_but_its_id_and_attempt
    classify = retry_step("classify", "Classify the failed jobs")
    rerun = retry_step("rerun", "Re-run the failed jobs once")
    assert_equal({"GH_TOKEN" => "${{ github.token }}", "RUN_ID" => "${{ github.event.workflow_run.id }}",
                  "RUN_ATTEMPT" => "${{ github.event.workflow_run.run_attempt }}"}, classify["env"])
    assert_equal({"GH_TOKEN" => "${{ github.token }}", "RUN_ID" => "${{ github.event.workflow_run.id }}"}, rerun["env"])
    retry_workflow.fetch("jobs").each do |name, job|
      job["steps"].each do |step|
        next unless step.key?("run")
        refute_includes step["run"], "github.event.workflow_run.", "#{name}: a script reads no field of the triggering run"
        refute_includes step["run"], "${{", "#{name}: a script has no expression"
      end
    end
  end

  # The steps run the real classifier through a fake `gh`; a re-run is requested once, for lost runners only.
  def test_the_retry_reruns_the_failed_jobs_only_when_every_failed_job_lost_its_runner
    root = File.expand_path("../..", __dir__)
    classify = retry_step("classify", "Classify the failed jobs")
    rerun = retry_step("rerun", "Re-run the failed jobs once")
    refute_nil classify
    refute_nil rerun
    lost = recorded_annotations.fetch("lost_runner")
    disk = recorded_annotations.fetch("disk_full")
    genuine = lost["job"].merge("id" => 77, "name" => "Test installed upgrades on macOS 27 host (1-of-1)",
                                "steps" => [{"name" => "Test installed upgrades", "status" => "completed", "conclusion" => "failure", "number" => 1}])
    notes = {lost.dig("job", "id") => lost["annotations"], disk.dig("job", "id") => disk["annotations"]}
    {"the real lost runner" => [[lost["job"]], "1", true], "the real full disk" => [[disk["job"]], "1", false],
     "a lost runner and a full disk" => [[lost["job"], disk["job"]], "1", false],
     "a lost runner and a failed job" => [[lost["job"], genuine], "1", false],
     "a failed job" => [[genuine], "1", false], "a second attempt" => [[lost["job"]], "2", false]}.each do |name, (jobs, attempt, expected)|
      Dir.mktmpdir do |dir|
        env = write_fake_gh(dir, jobs: jobs, annotations: notes).merge("RUN_ID" => "4242", "RUN_ATTEMPT" => attempt)
        assert system(env, "bash", "-c", classify.fetch("run"), chdir: root, out: File::NULL, err: File::NULL), name
        assert_includes File.read(File.join(dir, "calls.log")), "actions/runs/4242/attempts/#{attempt}/jobs"
        assert_equal expected, File.read(File.join(dir, "output")).include?("retry=true"), name
      end
    end
  end

  def test_the_rerun_requests_the_failed_jobs_once_and_only_while_the_run_is_still_at_attempt_one
    root = File.expand_path("../..", __dir__)
    rerun = retry_step("rerun", "Re-run the failed jobs once")
    {"1" => ["run rerun 4242 --failed --repo example/repository\n"], "2" => []}.each do |attempt, expected|
      Dir.mktmpdir do |dir|
        env = write_fake_gh(dir).merge("RUN_ID" => "4242", "GH_CURRENT_ATTEMPT" => attempt)
        ok = system(env, "bash", "-c", rerun.fetch("run"), chdir: root, out: File::NULL, err: File::NULL)
        assert ok, "attempt #{attempt.inspect}"
        calls = File.read(File.join(dir, "calls.log"))
        assert_includes calls, "api repos/example/repository/actions/runs/4242 --jq .run_attempt"
        assert_equal expected, calls.lines.grep(/\Arun rerun/), "attempt #{attempt.inspect}"
        assert_includes File.read(File.join(dir, "summary")), expected.empty? ? "is not re-run" : "re-run once"
      end
    end
  end

  def test_the_runner_disk_step_fails_below_the_declared_minimum_and_reads_it_from_the_matrix
    step = @jobs.fetch("upgrade").fetch("steps").find { |item| item["id"] == "disk" }
    refute_nil step
    assert_equal "${{ matrix.available_gib }}", step.fetch("env").fetch("REQUIRED_FREE_GIB")
    root = File.expand_path("../..", __dir__)
    Dir.mktmpdir do |dir|
      env = {"HOME" => dir, "GITHUB_STEP_SUMMARY" => File.join(dir, "summary")}
      assert system(env.merge("REQUIRED_FREE_GIB" => "0.001"), "bash", "-c", step.fetch("run"), chdir: root, out: File::NULL, err: File::NULL),
             "enough free disk must pass"
      refute system(env.merge("REQUIRED_FREE_GIB" => "1000000000"), "bash", "-c", step.fetch("run"), chdir: root, out: File::NULL, err: File::NULL),
             "a runner below the declared minimum must fail the job"
    end
  end

  def test_a_blocked_release_reports_the_disk_and_runtime_outcomes_of_the_failed_job
    upgrade = @jobs.fetch("upgrade").fetch("steps")
    report = upgrade.find { |step| step["name"] == "Report blocked release" }
    assert_equal "${{ steps.disk.outcome }}", report.fetch("env").fetch("DISK_OUTCOME")
    assert_equal "${{ steps.ios26-runtime.outcome }}", report.fetch("env").fetch("RUNTIME_OUTCOME")
    assert_includes report.fetch("run"), "$DISK_OUTCOME"
    assert_includes report.fetch("run"), "$RUNTIME_OUTCOME"
  end

  def test_runtime_provisioning_rejects_wrong_export_or_unavailable_runtime
    provision = @jobs.fetch("upgrade").fetch("steps").find { |step| step["id"] == "ios26-runtime" }.fetch("run")
    root = File.expand_path("../..", __dir__)
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "bin")
      Dir.mkdir(bin)
      File.write(File.join(bin, "xcodebuild"), <<~'SH')
        #!/bin/bash
        set -eu
        if [[ "$1" == "-downloadPlatform" ]]; then
          if [[ "${DOWNLOAD_FAIL:-0}" == 1 ]]; then exit 1; fi
          while [[ "$1" != "-exportPath" ]]; do shift; done
          root="$2/fixture.exportedBundle"
          mkdir -p "$root/Restore"
          version=26.5
          build=23F77
          [[ "${BAD_EXPORT:-0}" == 1 ]] && version=26.4
          [[ "${BAD_BUILD:-0}" == 1 ]] && build=23F99
          cat > "$root/ExportedMetadata.plist" <<EOF
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>MobileAssetProperties</key><dict><key>SimulatorVersion</key><string>$version</string><key>Build</key><string>$build</string></dict></dict></plist>
        EOF
          touch "$root/Restore/fixture.dmg"
          [[ "${EXTRA_IMAGE:-0}" == 1 ]] && touch "$root/Restore/other.dmg"
          [[ "${EXTRA_BUNDLE:-0}" == 1 ]] && mkdir -p "$2/other.exportedBundle"
          true
        elif [[ "$1" == "-importPlatform" ]]; then
          [[ "${IMPORT_FAIL:-0}" != 1 ]]
        else
          exit 1
        fi
      SH
      File.write(File.join(bin, "xcrun"), <<~'SH')
        #!/bin/bash
        if [[ -f "$(dirname "$0")/bad-runtime" ]]; then
          echo '{"runtimes": []}'
        else
          echo '{"runtimes": [{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","version":"26.5","buildversion":"23F77","isAvailable":true,"bundlePath":"'"$HOME"'/iOS 26.5.simruntime"}]}'
        fi
      SH
      File.chmod(0755, File.join(bin, "xcodebuild"))
      File.chmod(0755, File.join(bin, "xcrun"))
      # The journey scrubs the environment before it asks simctl for the installed runtimes, so the
      # fake bundle must live under one of the surviving variables: HOME.
      bundle = File.join(dir, "iOS 26.5.simruntime", "Contents", "Resources", "RuntimeRoot",
                          "System", "Library", "CoreServices")
      FileUtils.mkdir_p(bundle)
      File.binwrite(File.join(bundle, "SystemVersion.plist"),
                    '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'\
                    '<key>ProductBuildVersion</key><string>23F77</string></dict></plist>')
      env = {"PATH" => "#{bin}:#{ENV.fetch('PATH')}", "RUNNER_TEMP" => dir, "HOME" => dir,
             "UPGRADE_RUNTIME_ID" => "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
             "UPGRADE_RUNTIME_VERSION" => "26.5", "UPGRADE_RUNTIME_BUILD" => "23F77"}
      assert system(env, "bash", "-c", provision, chdir: root, out: File::NULL, err: File::NULL), "matching runtime must pass"
      %w[DOWNLOAD_FAIL BAD_BUILD BAD_EXPORT EXTRA_IMAGE EXTRA_BUNDLE IMPORT_FAIL BAD_RUNTIME].each do |failure|
        File.write(File.join(bin, "bad-runtime"), "") if failure == "BAD_RUNTIME"
        refute system(env.merge(failure => "1"), "bash", "-c", provision, chdir: root, out: File::NULL, err: File::NULL),
               "#{failure} must block the journey"
      end
    end
  end

  def test_the_journey_keeps_its_full_log_and_prints_its_results_and_disk
    upgrade = @jobs.fetch("upgrade")
    steps = upgrade.fetch("steps")
    run = steps.find { |step| step["name"] == "Test installed upgrades" }.fetch("run")
    assert_includes run, 'tee "$RUNNER_TEMP/release-upgrade.log"'
    assert_includes run, 'grep --line-buffered -aE "$JOURNEY_LINES" || true'
    lines = Regexp.new(upgrade.fetch("env").fetch("JOURNEY_LINES"))
    ["PASS iOS: v1.0.5 → abc, backup.claimed", "**Upgrade check failed:** The historical app did not reach x",
     "v1.0.5 / x preparation: the UI run started its first test case after 9 s",
     "v1.0.5 / x: case took 400 s, free disk 12.3 GiB", "Free disk after the builds: 20.0 GiB"].each do |line|
      assert_match lines, line
    end
    refute_match lines, "SwiftCompile normal arm64 Compiling Errors.swift"
    disk = steps.find { |step| step["name"] == "Report runner disk" }
    assert_includes disk.fetch("run"), 'df -h "$HOME"'
    assert_includes steps.find { |step| step["name"] == "List upgrade results" }.fetch("run"), 'df -h "$HOME"'
  end

  def test_upgrade_gate_has_no_release_secrets_or_implicit_failure_override
    upgrade = @jobs.fetch("upgrade")
    refute upgrade.key?("environment")
    refute upgrade.key?("continue-on-error")
    upgrade.fetch("steps").each { |step| refute step["continue-on-error"] }
    refute_includes upgrade.to_s, "secrets."
    run = upgrade.fetch("steps").find { |step| step["name"] == "Test installed upgrades" }
    assert_equal "needs.prepare.outputs.upgrade_overridden != 'true'", run.fetch("if")
    assert_includes run.fetch("env").fetch("TARGET_COMMIT"), "needs.prepare.outputs.commit_sha"
    assert_equal "${{ matrix.runner }}", upgrade.fetch("runs-on")
    assert_includes run.fetch("env").fetch("TARGET_RELEASE_TAG"), "needs.prepare.outputs.tag"
    assert_includes run.fetch("run"), '--release-tag "$TARGET_RELEASE_TAG"'
  end

  def test_approved_limits_and_setup_failures_are_always_reported
    steps = @jobs.fetch("upgrade").fetch("steps")
    scope = steps.find { |step| step["name"] == "Report upgrade check scope" }
    refute_nil scope
    assert_equal "always()", scope.fetch("if")
    Dir.mktmpdir do |directory|
      report = File.join(directory, "summary.md")
      assert system({ "GITHUB_STEP_SUMMARY" => report }, "bash", "-c", scope.fetch("run"))
      summary = File.read(report)
      assert_includes summary, "macOS-Keychain-Persistenz über das Update wird nicht im Prüfbau geprüft"
      assert_includes summary, "immediate v1.0.5 Enable-to-SIGKILL"
      assert_includes summary, "CFBundleShortVersionString and CFBundleVersion"
      assert_includes summary, "string-for-string"
      assert_includes summary, "External authentication-header acceptance remains unverified"
    end
    failure = steps.find { |step| step["name"] == "Report blocked release" }
    refute_nil failure
    assert_equal "failure() || cancelled()", failure.fetch("if")
    assert_includes failure.fetch("run"), "Both Apple uploads remain blocked"
    assert_includes failure.fetch("env").fetch("JOURNEY_OUTCOME"), "steps.journey.outcome"
  end

  def test_selection_reads_all_release_pages_and_requires_an_explicit_manual_override
    selection = @jobs.fetch("prepare").fetch("steps").find { |step| step["id"] == "upgrade-plan" }
    refute_nil selection
    assert_includes selection.fetch("run"), "--paginate"
    assert_includes selection.fetch("run"), "--slurp"
    assert_includes selection.fetch("run"), "release_upgrade.py"
    assert_includes selection.fetch("run"), '--override-reason="$OVERRIDE_REASON"'
    inputs = (@workflow["on"] || @workflow.fetch(true)).fetch("workflow_dispatch").fetch("inputs")
    assert inputs.key?("upgrade_override_tag")
    assert inputs.key?("upgrade_override_reason")
    refute inputs.key?("skip_upgrade")
  end
end
