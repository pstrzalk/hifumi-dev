require "test_helper"

class GithubConnectionTest < ActiveSupport::TestCase
  setup do
    @user = create_user
  end

  # --- validations ------------------------------------------------------

  test "is valid with all required attributes" do
    conn = @user.build_github_connection(
      provider: "github_oauth",
      github_username: "octocat",
      github_user_id: 583231,
      access_token: "gho_test"
    )
    assert conn.valid?
  end

  test "requires provider" do
    conn = @user.build_github_connection(
      github_username: "octocat", github_user_id: 1, access_token: "gho_x"
    )
    conn.provider = nil
    refute conn.valid?
    assert_includes conn.errors[:provider], "can't be blank"
  end

  test "requires github_username" do
    conn = @user.build_github_connection(
      provider: "github_oauth", github_user_id: 1, access_token: "gho_x"
    )
    refute conn.valid?
    assert_includes conn.errors[:github_username], "can't be blank"
  end

  test "requires github_user_id" do
    conn = @user.build_github_connection(
      provider: "github_oauth", github_username: "octocat", access_token: "gho_x"
    )
    refute conn.valid?
    assert_includes conn.errors[:github_user_id], "can't be blank"
  end

  test "requires access_token" do
    conn = @user.build_github_connection(
      provider: "github_oauth", github_username: "octocat", github_user_id: 1
    )
    refute conn.valid?
    assert_includes conn.errors[:access_token], "can't be blank"
  end

  test "provider must be in inclusion list" do
    conn = @user.build_github_connection(
      provider: "gitlab",
      github_username: "octocat",
      github_user_id: 1,
      access_token: "gho_x"
    )
    refute conn.valid?
    assert_includes conn.errors[:provider], "is not included in the list"
  end

  test "accepts github_app as a provider value" do
    conn = @user.build_github_connection(
      provider: "github_app",
      github_username: "octocat",
      github_user_id: 1,
      access_token: "ghu_x"
    )
    assert conn.valid?
  end

  # --- predicates -------------------------------------------------------

  test "connected? is true when access_token is present" do
    conn = @user.create_github_connection!(
      provider: "github_oauth",
      github_username: "octocat",
      github_user_id: 1,
      access_token: "gho_x"
    )
    assert conn.connected?
  end

  test "expired? is false when expires_at is nil (OAuth-app token)" do
    conn = @user.create_github_connection!(
      provider: "github_oauth",
      github_username: "octocat",
      github_user_id: 1,
      access_token: "gho_x"
    )
    refute conn.expired?
  end

  test "expired? is true when expires_at is in the past" do
    conn = @user.create_github_connection!(
      provider: "github_app",
      github_username: "octocat",
      github_user_id: 1,
      access_token: "ghu_x",
      expires_at: 1.hour.ago
    )
    assert conn.expired?
  end

  test "expired? is false when expires_at is in the future" do
    conn = @user.create_github_connection!(
      provider: "github_app",
      github_username: "octocat",
      github_user_id: 1,
      access_token: "ghu_x",
      expires_at: 1.hour.from_now
    )
    refute conn.expired?
  end

  test "github_url builds an https profile URL from the username" do
    conn = @user.build_github_connection(github_username: "octocat", github_user_id: 1, access_token: "x")
    assert_equal "https://github.com/octocat", conn.github_url
  end

  # --- encryption -------------------------------------------------------

  test "access_token round-trips through encrypts (decrypted on reload)" do
    conn = @user.create_github_connection!(
      provider: "github_oauth",
      github_username: "octocat",
      github_user_id: 1,
      access_token: "gho_secret_value"
    )

    # Stored ciphertext in the raw column is not the plaintext.
    raw = GithubConnection.connection.select_value(
      "SELECT access_token FROM github_connections WHERE id = #{conn.id}"
    )
    refute_equal "gho_secret_value", raw,
                 "access_token must be encrypted at rest, not stored in plaintext"

    # Reload through the model decrypts it.
    assert_equal "gho_secret_value", conn.reload.access_token
  end

  test "refresh_token round-trips nil safely (encryption is no-op for nil)" do
    conn = @user.create_github_connection!(
      provider: "github_oauth",
      github_username: "octocat",
      github_user_id: 1,
      access_token: "gho_x",
      refresh_token: nil
    )
    assert_nil conn.reload.refresh_token
  end

  # --- association ------------------------------------------------------

  test "User#github_connection returns the row" do
    @user.create_github_connection!(
      provider: "github_oauth",
      github_username: "octocat",
      github_user_id: 1,
      access_token: "gho_x"
    )
    assert_equal "octocat", @user.reload.github_connection.github_username
  end

  test "destroying the user destroys the github_connection (dependent: :destroy)" do
    @user.create_github_connection!(
      provider: "github_oauth",
      github_username: "octocat",
      github_user_id: 1,
      access_token: "gho_x"
    )
    assert_difference -> { GithubConnection.count }, -1 do
      @user.destroy!
    end
  end
end
