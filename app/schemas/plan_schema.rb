class PlanSchema < RubyLLM::Schema
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
