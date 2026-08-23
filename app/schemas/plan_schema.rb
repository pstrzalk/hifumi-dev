# Schematist ships as a RubyLLM v2 runtime dependency, but the gem only
# `require`s it from lazily-loaded files (tool.rb, agent.rb), so the constant
# is not guaranteed to exist when Rails autoloads this class.
require "schematist"

class PlanSchema < Schematist::Schema
  string :instruction_description,
         description: "One-sentence human description of the whole plan."

  array :revisions,
        description: "Ordered list of 3 to 6 atomic revisions." do
    object do
      string :summary, description: "Git-commit-style one-liner summarising this revision."
      string :prompt,  description: "Concrete, file-level instruction passed to the implementer agent."
    end
  end
end
