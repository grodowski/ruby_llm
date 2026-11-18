# frozen_string_literal: true

module RubyLLM
  class Evaluation
    # A run's trials and summary. Persist with #save for review and comparisons.
    class Report
      include Enumerable
      include Support::Inspectable
      include Accounting::Usage::Result

      # Returns the evaluation class name.
      attr_reader :name
      # Returns the unique run identifier.
      attr_reader :id
      # Returns the trials in dataset and repetition order.
      attr_reader :trials
      # Returns the UTC time the run started.
      attr_reader :started_at
      # Returns the criterion definitions and evaluator identities captured for this run.
      attr_reader :definitions

      def initialize(name:, trials:, id:, started_at:, definitions:) # :nodoc:
        @name = name
        @trials = trials.freeze
        @ruby_llm_usage_entries = trials.flat_map(&:ruby_llm_usage_entries).freeze
        @id = id
        @started_at = started_at
        @definitions = Judge::Data.copy(definitions)
        freeze
      end

      # Yields each trial, or returns an Enumerator.
      def each(&)
        trials.each(&)
      end

      # Returns the Tokens aggregate across every case and repetition.
      def tokens
        ruby_llm_usage_tokens
      end

      # Returns the Cost aggregate across every case and repetition.
      def cost
        ruby_llm_usage_cost
      end

      # Returns trial counts keyed by status.
      def counts
        totals = trials.map(&:status).tally
        %i[passed failed measured unassessed error].to_h { |status| [status, totals.fetch(status, 0)] }
      end

      # UndercoverCI demo, scenario 8 of 9: touching an old gap. This PR
      # changes this line (counts[:passed] -> counts.fetch(:passed)), and the
      # specs run it, but none builds an empty report, so the nil side of the
      # ternary has never run. Undercover checks the branches on every changed
      # line, flags pass_rate, and names the branch ("? trials.empty? ->
      # then"). The gap is older than this PR; touching the line makes it
      # this PR's to close.
      #
      # Returns the passing fraction of all trials, including errors and ungraded measurements.
      def pass_rate
        trials.empty? ? nil : counts.fetch(:passed).fdiv(trials.size)
      end

      # Returns true only when the run is nonempty and every trial passed.
      def passed?
        trials.any? && trials.all?(&:passed?)
      end

      # UndercoverCI demo, scenario 1 of 9: a new method with a spec.
      # report_undercover_demo_spec.rb runs it, so undercover has nothing to
      # report here. Tested changes stay quiet: there is no coverage
      # percentage to defend.
      #
      # Returns the trials that did not pass, in run order.
      def failures
        trials.reject(&:passed?)
      end

      # UndercoverCI demo, scenario 2 of 9: a new method no spec calls.
      # Undercover attributes each changed line to the innermost method,
      # block or class around it, so this is reported as one warning,
      # "instance method trials_with" at 0%, and UndercoverCI annotates the
      # method in the PR diff. Had the body been a block, like
      # trials.select { ... }, the warning would name the block instead.
      #
      # Returns the trials whose status is +status+, such as +:failed+.
      def trials_with(status)
        trials.group_by(&:status).fetch(status, [])
      end

      # UndercoverCI demo, scenario 3 of 9: every line runs, one branch never
      # does. The spec only builds nonempty reports, so the "no trials" side
      # of the ternary has 0 hits. Undercover flags the method and names the
      # missed branch ("? trials.empty? -> then") in its JSON output. Line
      # coverage alone reports this method as 100%.
      #
      # Returns a one-line summary, such as "Greeter: 2/3 passed".
      def headline
        trials.empty? ? "#{name}: no trials" : "#{name}: #{counts[:passed]}/#{trials.size} passed"
      end

      # UndercoverCI demo, scenario 4 of 9: untested blocks. The +each+ block
      # runs when the file loads, so it counts as covered, but no spec calls
      # the methods it defines. The define_method body is its own block node,
      # and undercover flags that block, not the loop around it. The body
      # sits on its own line on purpose: coverage is per line, and a
      # one-line `define_method(...) { ... }` counts as run as soon as the
      # file loads.
      %i[passed failed error].each do |status|
        define_method(:"#{status}_count") do # :nodoc:
          counts[status]
        end
      end

      # UndercoverCI demo, scenario 5 of 9: a new class method with no spec.
      # It's reported as "class method pass_rate_of", next to the instance
      # methods.
      #
      # Returns the passing fraction across several reports, or +nil+ when
      # they have no trials.
      def self.pass_rate_of(reports)
        trials = reports.flat_map(&:trials)
        trials.empty? ? nil : trials.count(&:passed?).fdiv(trials.size)
      end

      # UndercoverCI demo, scenario 6 of 9: skipped on purpose. Code that
      # can't run in a spec goes between simplecov:disable and
      # simplecov:enable, which SimpleCov and undercover both honor, so this
      # method isn't reported. Keep these regions rare and small: a real
      # spec beats a skip.
      # simplecov:disable
      def debug_dump # :nodoc:
        warn JSON.pretty_generate(to_h) if $stderr.tty?
      end
      # simplecov:enable

      # Returns all trial evidence, measurements, and run identity as a Hash.
      def to_h
        { id:, name:, started_at: started_at.iso8601, definitions:, counts:, pass_rate:,
          tokens: tokens.to_h, cost: cost.to_h, trials: trials.map(&:to_h) }
      end

      # Writes a JSON report and returns the supplied path.
      def save(path)
        File.write(File.expand_path(path), JSON.pretty_generate(to_h))
        path
      end

      # Returns a readable per-case report followed by counts, and the total
      # cost when every amount is known.
      def to_s
        rows = trials.map { |trial| trial_description(trial) }
        total = cost.total
        summary = counts.map { |status, count| "#{count} #{status}" }.join(', ')
        summary += format(', cost $%.4f', total) if total
        [name, *rows, summary].join("\n")
      end

      def inspect_attributes # :nodoc:
        { name:, trials: trials.size, **counts }
      end

      private

      def trial_description(trial)
        details = trial.evaluations.map { |item| "#{item.name}=#{item.status}" }.join(', ')
        heading = "#{trial.test_case.name} [#{trial.repetition}]: #{trial.status}"
        heading += " (#{details})" unless details.empty?
        [heading, *failure_messages(trial).map { |failure| "  #{failure}" }].join("\n")
      end

      # UndercoverCI demo, scenario 7 of 9: old gaps don't block unrelated
      # changes. This PR changes only the last line (compact ->
      # compact.uniq), and existing specs run it, so undercover stays quiet.
      # Two older gaps are in this method and stay unreported: no spec
      # renders a trial with an error, so `trial.error&.message` never takes
      # its non-nil branch, and the evaluation message line in the block
      # never runs. Undercover judges the lines a change touches, so a PR
      # isn't blamed for debt it didn't touch; scenario 8 shows what happens
      # when it does.
      def failure_messages(trial)
        messages = [trial.error&.message, trial.assertion_failure&.message]
        messages.concat(trial.evaluations.reject(&:passed?).map do |item|
          "#{item.name}: #{item.error&.message || item.reason || item.value.inspect}"
        end)
        messages.compact.uniq
      end
    end
  end
end
