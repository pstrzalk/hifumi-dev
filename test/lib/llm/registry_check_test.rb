require "test_helper"

class LLM::RegistryCheckTest < ActiveSupport::TestCase
  # RubyLLM::Models.instance is memoised per process on first use. Two tests
  # below delete store rows; if one of them were the first in this worker to
  # resolve anything, the process would memoise the bundle (or a 4-row
  # registry) for every later test — order-dependent flakiness. Resolve once
  # against the intact fixture store first.
  setup do
    RubyLLM::Models.resolve(LLM::Stages::AVAILABLE_MODELS.keys.first, provider: LLM::Stages::PROVIDER)
  end

  test "ok when the store carries every offered id under the pinned provider" do
    result = LLM::RegistryCheck.call
    assert result.ok?, "missing=#{result.missing_rows} unresolved=#{result.unresolved}"
    assert_equal LLM::Stages::AVAILABLE_MODELS.size, result.store_rows
  end

  # The memoised registry still holds the five fixture models after the
  # deletes below, so `unresolved` is deliberately not asserted there —
  # store_rows / missing_rows are the live-DB signals the bin's exit code keys on.
  test "not ok when the store is empty" do
    RubyLLM::ActiveRecord::Model.delete_all
    result = LLM::RegistryCheck.call
    refute result.ok?
    assert_equal 0, result.store_rows
    assert_equal LLM::Stages::AVAILABLE_MODELS.keys, result.missing_rows
  end

  test "not ok when one offered id has no row under the pinned provider" do
    RubyLLM::ActiveRecord::Model.find_by!(model_id: "anthropic/claude-opus-5").destroy!
    result = LLM::RegistryCheck.call
    refute result.ok?
    assert_equal [ "anthropic/claude-opus-5" ], result.missing_rows
  end

  test "a candidate absent from the store reports its error without affecting ok?" do
    result = LLM::RegistryCheck.call(candidates: [ "anthropic/claude-nonexistent-9" ])
    assert result.ok?
    candidate = result.candidates.first
    refute candidate.ok?
    assert_equal "RubyLLM::ModelNotFoundError", candidate.error
  end
end
