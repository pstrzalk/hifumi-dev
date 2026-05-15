require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    cookies[:cookie_consent] = "accepted"
    @project = projects(:flowers)
    sign_in users(:owner)
  end

  test "POST with valid content creates a user message on the project's chat" do
    assert_difference -> { @project.chat.messages.count } => 1 do
      post project_messages_path(@project), params: { message: { content: "Add Tailwind" } }
    end
    message = @project.chat.messages.order(:created_at).last
    assert_equal "user", message.role
    assert_equal "Add Tailwind", message.content
  end

  test "POST with valid HTML Accept redirects to project" do
    post project_messages_path(@project), params: { message: { content: "Add Tailwind" } }
    assert_redirected_to project_path(@project)
  end

  test "POST with valid turbo_stream Accept replaces the form instead of redirecting" do
    post project_messages_path(@project),
         params: { message: { content: "Add Tailwind" } },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_match(/turbo-stream action="replace" target="#{ActionView::RecordIdentifier.dom_id(@project, :message_form)}"/, @response.body)
  end

  test "POST with blank content does not persist" do
    assert_no_difference -> { @project.chat.messages.count } do
      post project_messages_path(@project), params: { message: { content: "" } }
    end
  end

  test "POST with blank content (HTML) redirects with alert" do
    post project_messages_path(@project), params: { message: { content: "" } }
    assert_redirected_to project_path(@project)
    assert_equal "Message cannot be blank.", flash[:alert]
  end

  test "POST with blank content (turbo_stream) returns 422 and re-renders the form" do
    post project_messages_path(@project),
         params: { message: { content: "" } },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :unprocessable_entity
    assert_match(/turbo-stream action="replace" target="#{ActionView::RecordIdentifier.dom_id(@project, :message_form)}"/, @response.body)
  end

  test "POST with whitespace-only content is treated as blank" do
    assert_no_difference -> { @project.chat.messages.count } do
      post project_messages_path(@project), params: { message: { content: "   \n\t  " } }
    end
    assert_equal "Message cannot be blank.", flash[:alert]
  end

  test "POST with unknown project_id returns 404" do
    post project_messages_path(project_id: 999999), params: { message: { content: "hello" } }
    assert_response :not_found
  end

  test "POST without auth redirects to login" do
    sign_out users(:owner)
    assert_no_difference -> { @project.chat.messages.count } do
      post project_messages_path(@project), params: { message: { content: "hi" } }
    end
    assert_redirected_to new_user_session_path
  end

  test "POST as non-owner redirects to root with 'Not your project'" do
    sign_out users(:owner)
    sign_in users(:other)
    assert_no_difference -> { @project.chat.messages.count } do
      post project_messages_path(@project), params: { message: { content: "hi" } }
    end
    assert_redirected_to root_path
    assert_equal "Not your project", flash[:alert]
  end

  test "POST (valid) enqueues ChatRespondJob with the new message id" do
    assert_enqueued_with(job: ChatRespondJob) do
      post project_messages_path(@project), params: { message: { content: "Keep going" } }
    end
    message = @project.chat.messages.order(:created_at).last
    assert_enqueued_with(job: ChatRespondJob, args: [ message.id ])
  end

  test "POST (blank) does NOT enqueue ChatRespondJob" do
    assert_no_enqueued_jobs(only: ChatRespondJob) do
      post project_messages_path(@project), params: { message: { content: "" } }
    end
  end

  test "POST with multiline content preserves newlines" do
    post project_messages_path(@project), params: { message: { content: "line one\nline two" } }
    assert_equal "line one\nline two", @project.chat.messages.order(:created_at).last.content
  end
end
