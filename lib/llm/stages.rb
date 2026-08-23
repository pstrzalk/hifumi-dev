# frozen_string_literal: true

# Registry of the LLM-backed steps of project creation ("stages") and the
# OpenRouter models offered for each of them.
#
# Single source of truth for:
#   - which stages exist and the Profile/Project columns that store their model
#   - the model offered as factory default for each stage
#   - the curated list of models a user may pick from
#
# A user's Profile holds their personal defaults (`default_<stage>_model`),
# applied to every project they create; each Project snapshots its own
# selection (`<stage>_model`) so later default changes don't retroactively
# alter running projects.
#
# Models are full OpenRouter IDs, never the claude CLI's short aliases
# ("sonnet"/"haiku") — bin/roast-openrouter passes full IDs through verbatim,
# and RubyLLM resolves them against its registry. The list is curated to
# models known to work on every stage: the code/docs stages run through the
# `claude` CLI's Anthropic API surface, and the plan/template stages need
# structured output — both rule out arbitrary OpenRouter catalog entries.
#
# Adding an id here is NOT sufficient. RubyLLM must also be able to resolve it:
# it reads the `ruby_llm_models` table as its registry store and falls back to
# the gem's bundled registry only when that table is empty, so an id missing
# from both raises ModelNotFoundError. Run `bin/verify-model-registry <id>`
# before shipping a new entry, and populate with `RubyLLM.models.refresh!`.
# Procedure: docs/05-runbooks/03-llm-model-registry.md.
#
# Deliberate exclusions (2026-08-12), so they don't get "fixed" back in:
#   - `:batch` and `-fast` variants — async Batch API / premium fast mode, both
#     wrong for a synchronous picker.
#   - claude-3-haiku, opus-4, opus-4.1, sonnet-4 — no structured_output, which
#     the plan and template stages require.
#   - opus-4.5 / 4.7 / 4.8 and sonnet-4.5 — usable, but superseded within their
#     own tier at identical pricing. Opus 4.8 is worth adding if refusal
#     fallbacks are ever implemented: it is Anthropic's documented fallback
#     target for Opus 5 declines.
#   - claude-fable-5 — its safety classifiers decline requests as HTTP 200 with
#     `stop_reason: "refusal"`, not an error. Nothing here handles that: chat
#     would persist a blank assistant message, and Templates::Picker would raise
#     InvalidPick into an unrescued ExecuteInstructionJob. Needs refusal
#     handling first.
module LLM
  module Stages
    AVAILABLE_MODELS = {
      "anthropic/claude-haiku-4.5"  => "Claude Haiku 4.5",
      "anthropic/claude-sonnet-4.6" => "Claude Sonnet 4.6",
      "anthropic/claude-sonnet-5"   => "Claude Sonnet 5",
      "anthropic/claude-opus-4.6"   => "Claude Opus 4.6",
      "anthropic/claude-opus-5"     => "Claude Opus 5"
    }.freeze

    Stage = Struct.new(:key, :label, :default_model, keyword_init: true) do
      def project_column
        :"#{key}_model"
      end

      def profile_column
        :"default_#{key}_model"
      end
    end

    ALL = [
      Stage.new(key: :chat,              label: "Chat replies",        default_model: "anthropic/claude-haiku-4.5"),
      Stage.new(key: :plan_creation,     label: "Plan for a new app",  default_model: "anthropic/claude-haiku-4.5"),
      Stage.new(key: :plan_modification, label: "Plan for changes",    default_model: "anthropic/claude-haiku-4.5"),
      Stage.new(key: :template,          label: "Template choice",     default_model: "anthropic/claude-haiku-4.5"),
      Stage.new(key: :code,              label: "Code generation",     default_model: "anthropic/claude-sonnet-4.6"),
      Stage.new(key: :docs,              label: "Docs update",         default_model: "anthropic/claude-haiku-4.5")
    ].freeze

    def self.find(key)
      ALL.find { |stage| stage.key == key.to_sym } ||
        raise(KeyError, "unknown LLM stage #{key.inspect}")
    end

    def self.project_columns
      ALL.map(&:project_column)
    end

    def self.profile_columns
      ALL.map(&:profile_column)
    end
  end
end
