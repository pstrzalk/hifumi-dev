require "test_helper"

class SeedsTest < ActiveSupport::TestCase
  test "seeds create one store row per offered model under the pinned provider" do
    RubyLLM::ActiveRecord::Model.delete_all
    Rails.application.load_seed

    expected = LLM::Stages::AVAILABLE_MODELS.keys.map { |id| [ LLM::Stages::PROVIDER.to_s, id ] }.sort
    assert_equal expected, RubyLLM::ActiveRecord::Model.pluck(:provider, :model_id).sort
  end

  test "seeds are idempotent on a populated store" do
    assert_no_difference("RubyLLM::ActiveRecord::Model.count") { Rails.application.load_seed }
  end
end
