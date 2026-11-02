# frozen_string_literal: true

require 'spec_helper'

# UndercoverCI demo: the specs for the scenarios in Evaluation::Report.
# Changes under spec/ are excluded from undercover's check by default
# (--exclude-files), so this file never shows up as a warning itself; it only
# changes what the lib/ nodes report.
RSpec.describe RubyLLM::Evaluation::Report do
  include_context 'with configured RubyLLM'

  let(:evaluation) do
    Class.new(RubyLLM::Evaluation) do
      evaluator false

      def self.name = 'Greeter'

      def perform(input)
        input.upcase
      end

      def assertions
        assert_equal expected_output, output
      end
    end
  end
  let(:cases) do
    [
      RubyLLM::Evaluation::Case.new(name: 'hello', inputs: 'hello', expected_output: 'HELLO'),
      RubyLLM::Evaluation::Case.new(name: 'bye', inputs: 'bye', expected_output: 'BYE'),
      RubyLLM::Evaluation::Case.new(name: 'typo', inputs: 'wrong', expected_output: 'RIGHT')
    ]
  end
  let(:report) { evaluation.run(dataset: cases) }

  # Scenario 1: every line of #failures runs, so undercover stays quiet.
  it 'lists the trials that did not pass' do
    expect(report.failures.map { |trial| trial.test_case.name }).to eq(['typo'])
  end

  # Scenario 3: only the nonempty side of #headline runs. The "no trials"
  # branch stays at 0 hits, and undercover names it.
  it 'summarizes the run in one line' do
    expect(report.headline).to eq('Greeter: 2/3 passed')
  end
end
