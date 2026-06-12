require "test_helper"

class ModelSelectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    cookies[:cookie_consent] = "accepted"
    @user = create_user
    sign_in @user
    @project = @user.projects.create!(name: "Model Selection Test")
  end

  test "PATCH (owner) updates every stage model and re-renders the pane with a saved note" do
    selection = LLM::Stages.project_columns.to_h { |column| [ column, "anthropic/claude-opus-4.6" ] }

    patch project_model_selection_path(@project), params: { project: selection }

    assert_response :success
    @project.reload
    LLM::Stages.project_columns.each do |column|
      assert_equal "anthropic/claude-opus-4.6", @project[column],
        "expected #{column} to be updated"
    end
    assert_select "turbo-frame#model_selection_pane"
    assert_select "details[open]"
    assert_match(/Saved\./, @response.body)
  end

  test "PATCH with a model outside the available list returns 422 and changes nothing" do
    patch project_model_selection_path(@project), params: {
      project: { chat_model: "openai/gpt-4o" }
    }

    assert_response :unprocessable_entity
    assert_equal "anthropic/claude-haiku-4.5", @project.reload.chat_model
    assert_select ".notice-strip--err .notice-strip__body", text: /is not an available model/
  end

  test "PATCH as non-owner redirects to root with 'Not your project'" do
    sign_out @user
    sign_in users(:other)

    patch project_model_selection_path(@project), params: {
      project: { chat_model: "anthropic/claude-opus-4.6" }
    }

    assert_redirected_to root_path
    assert_equal "Not your project", flash[:alert]
    assert_equal "anthropic/claude-haiku-4.5", @project.reload.chat_model
  end

  test "PATCH without auth redirects to login" do
    sign_out @user

    patch project_model_selection_path(@project), params: {
      project: { chat_model: "anthropic/claude-opus-4.6" }
    }

    assert_redirected_to new_user_session_path
    assert_equal "anthropic/claude-haiku-4.5", @project.reload.chat_model
  end
end
