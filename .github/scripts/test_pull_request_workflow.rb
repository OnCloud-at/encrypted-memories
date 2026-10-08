require "minitest/autorun"
require "yaml"

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
    source = source.gsub(/github\.[a-z_.]+/) { |path| context.fetch(path, nil).inspect }
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
      assert [nil, "${{ always() }}"].include?(job["if"]), name
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
end
