class GithubConnection < ApplicationRecord
  belongs_to :user, inverse_of: :github_connection

  encrypts :access_token
  encrypts :refresh_token

  validates :provider, :github_username, :github_user_id, :access_token, presence: true
  validates :provider, inclusion: { in: %w[github_oauth github_app] }

  # Today this is functionally `access_token.present?` (and the row only
  # exists when there's a token), but keep the predicate — Phase 5 (GitHub
  # App migration) will make it meaningful: an `expired?` token + no
  # refresh_token will mean "row exists but not currently usable".
  def connected? = access_token.present?

  # True only when the token has a known expiry that's in the past.
  # OAuth-app tokens never expire (expires_at is nil) — connected? is the only check.
  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def github_url = "https://github.com/#{github_username}"
end
