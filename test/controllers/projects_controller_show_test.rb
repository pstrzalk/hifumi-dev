require "test_helper"

class ProjectsControllerShowTest < ActionDispatch::IntegrationTest
  setup do
    cookies[:cookie_consent] = "accepted"
    @user = create_user
    sign_in @user
    @project = @user.projects.create!(name: "Shop")
    @chat = @project.create_chat!
    @user_message = @chat.messages.create!(role: :user, content: "flower shop")
  end

  test "renders empty active_revisions slot when no instruction exists" do
    get project_url(@project)
    assert_response :success
    assert_select "div#active_revisions", 1
    assert_select "div#active_revisions *", false
  end

  test "renders active_revisions list when an implementing instruction has revisions" do
    instruction = @project.instructions.create!(
      user_intent: "x", description: "x",
      phase: :implementing, anchor_message: @user_message
    )
    instruction.revisions.create!(
      project: @project, position: 0, status: :pending,
      summary: "Add Task model", prompt: "p"
    )

    get project_url(@project)
    assert_response :success
    assert_select "div#active_revisions .revisions__head", /current instruction/
    assert_select "div#active_revisions", /Add Task model/
    assert_select "div#active_revisions", /pending/
  end

  test "hides revisions for terminal-phase instructions" do
    instruction = @project.instructions.create!(
      user_intent: "x", description: "x",
      phase: :completed, anchor_message: @user_message
    )
    instruction.revisions.create!(
      project: @project, position: 0, status: :completed,
      summary: "Done", prompt: "p", git_sha: "abc1234"
    )

    get project_url(@project)
    assert_response :success
    assert_select "div#active_revisions *", false
  end

  test "renders git_sha (first 7 chars) on completed revision card" do
    instruction = @project.instructions.create!(
      user_intent: "x", description: "x",
      phase: :implementing, anchor_message: @user_message
    )
    instruction.revisions.create!(
      project: @project, position: 0, status: :completed,
      summary: "Add model", prompt: "p", git_sha: "abc1234deadbeef"
    )

    get project_url(@project)
    assert_select "div#active_revisions", /abc1234\b/
  end

  test "renders three tab buttons (build / preview / export) with kanji glyphs and mono labels" do
    get project_url(@project)
    assert_response :success
    assert_select "nav.tab-nav[role=tablist][aria-label=?]", "studio sections", 1
    assert_select "nav.tab-nav button.tab-button[data-tab-name=build]" do
      assert_select "span.tab-button__numeral.kanji", text: "一"
      assert_select "span.tab-button__label", text: /build/i
    end
    assert_select "nav.tab-nav button.tab-button[data-tab-name=preview]" do
      assert_select "span.tab-button__numeral.kanji", text: "二"
      assert_select "span.tab-button__label", text: /preview/i
    end
    assert_select "nav.tab-nav button.tab-button[data-tab-name=export]" do
      assert_select "span.tab-button__numeral.kanji", text: "三"
      assert_select "span.tab-button__label", text: /export/i
    end
  end

  test "build is the default-active tab; preview and export are inactive (aria + roving tabindex)" do
    get project_url(@project)
    assert_response :success
    assert_select "button.tab-button.is-active[data-tab-name=build][aria-selected=true][tabindex=?]", "0", 1
    assert_select "button.tab-button[data-tab-name=preview][aria-selected=false][tabindex=?]", "-1", 1
    assert_select "button.tab-button[data-tab-name=export][aria-selected=false][tabindex=?]", "-1", 1
    assert_select "button.tab-button.is-active", 1
  end

  test "tab buttons declare aria-controls pointing at their pane ids" do
    get project_url(@project)
    assert_response :success
    assert_select "button#tab_build[role=tab][aria-controls=pane_build]", 1
    assert_select "button#tab_preview[role=tab][aria-controls=pane_preview]", 1
    assert_select "button#tab_export[role=tab][aria-controls=pane_export]", 1
  end

  test "tab buttons wire keydown to tabs#keydown for arrow-key navigation" do
    get project_url(@project)
    assert_response :success
    %w[build preview export].each do |name|
      assert_select "button[data-tab-name=#{name}][data-action*=?]", "click->tabs#switch", 1
      assert_select "button[data-tab-name=#{name}][data-action*=?]", "keydown->tabs#keydown", 1
    end
  end

  test "all three tab panes are role=tabpanel, labelled by their tab, and present in the DOM" do
    get project_url(@project)
    assert_response :success
    assert_select "div#pane_build[role=tabpanel][aria-labelledby=tab_build][data-tab-name=build]", 1
    assert_select "div#pane_preview[role=tabpanel][aria-labelledby=tab_preview][data-tab-name=preview][style*=?]",
      "display: none", 1
    assert_select "div#pane_export[role=tabpanel][aria-labelledby=tab_export][data-tab-name=export][style*=?]",
      "display: none", 1
  end

  test "every Turbo broadcast target id is present in the rendered DOM" do
    get project_url(@project)
    assert_response :success
    assert_select "div#chat_notice", true,
      "chat_notice slot must exist for ChatRespondJob#broadcast_chat_notice (chat_respond_job.rb:62-69)"
    assert_select "div#active_revisions", true,
      "active_revisions slot must exist for event_subscribers.rb:13-18,50-55,109-114"
    assert_select "div#messages", true,
      "messages container must exist for Message#broadcast_append_message (message.rb:5,16-23)"
    assert_select "div#preview", true,
      "preview slot must exist for PreviewManager#broadcast (preview_manager.rb:325-332)"
    assert_select "turbo-frame#github_export_pane", true,
      "github_export_pane frame must exist for ExportToGithubJob#broadcast (export_to_github_job.rb:108-115)"
    assert_select "form#message_form_project_#{@project.id}", true,
      "message form id must exist for MessagesController#create turbo_stream response"
  end

  test "build pane contains the messages feed and the composer form" do
    get project_url(@project)
    assert_response :success
    assert_select "div#pane_build[data-tab-name=build]" do
      assert_select "div#messages", 1
      assert_select "form#message_form_project_#{@project.id}", 1
    end
  end

  test "preview pane contains the active_revisions list above the preview slot" do
    get project_url(@project)
    assert_response :success
    assert_select "div#pane_preview[data-tab-name=preview]" do
      assert_select "div#active_revisions", 1
      assert_select "div#preview", 1
    end
  end

  test "export pane contains the github_export turbo frame" do
    get project_url(@project)
    assert_response :success
    assert_select "div#pane_export[data-tab-name=export]" do
      assert_select "turbo-frame#github_export_pane", 1
    end
  end

  test "duplicated inline flash strip is gone; layout-level strip still renders (regression guard)" do
    post project_messages_url(@project), params: { message: { content: "" } }
    follow_redirect!
    assert_response :success
    assert_select "main .notice-strip--err", 1
    assert_select "div#pane_build .notice-strip--err", 0
  end
end
