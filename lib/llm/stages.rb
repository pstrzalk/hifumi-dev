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
module LLM
  module Stages
    AVAILABLE_MODELS = {
      "anthropic/claude-haiku-4.5"  => "Claude Haiku 4.5",
      "anthropic/claude-sonnet-4.6" => "Claude Sonnet 4.6",
      "anthropic/claude-opus-4.6"   => "Claude Opus 4.6"
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
