# frozen_string_literal: true

# Is the RubyLLM registry store in the state db/seeds.rb leaves it in — one
# PROVIDER row per LLM::Stages::AVAILABLE_MODELS id — and does RubyLLM's
# memoised registry agree? Pure report, no writes, no network.
#
# `offered` and `candidates` both carry full Resolutions so the caller prints
# from the report and each id is resolved exactly once; `unresolved` derives
# from `offered`. A failing candidate does not flip ok? — a candidate is a
# model being checked BEFORE it is offered, so its absence is information, not
# a defect in the store.
module LLM
  module RegistryCheck
    Result = Struct.new(:store_rows, :missing_rows, :offered, :candidates, keyword_init: true) do
      def ok? = store_rows.positive? && missing_rows.empty? && unresolved.empty?
      def unresolved = offered.reject(&:ok?).map(&:id)
    end

    Resolution = Struct.new(:id, :provider, :context_window, :error, keyword_init: true) do
      def ok? = error.nil?
    end

    def self.call(candidates: [])
      store = RubyLLM::ActiveRecord::Model
      offered = LLM::Stages::AVAILABLE_MODELS.keys
      Result.new(
        store_rows: store.count,
        missing_rows: offered.reject { |id| store.exists?(model_id: id, provider: LLM::Stages::PROVIDER.to_s) },
        offered: offered.map { |id| resolve(id) },
        candidates: candidates.map { |id| resolve(id) }
      )
    end

    def self.resolve(id)
      info, = RubyLLM::Models.resolve(id, provider: LLM::Stages::PROVIDER)
      Resolution.new(id: id, provider: info.provider, context_window: info.context_window)
    rescue StandardError => e
      Resolution.new(id: id, error: e.class.name)
    end
  end
end
