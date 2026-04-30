require "test_helper"

class DeviseMailerTest < ActionMailer::TestCase
  test "reset_password_instructions renders" do
    user = users(:owner)
    token = user.send(:set_reset_password_token)

    mail = Devise::Mailer.reset_password_instructions(user, token)

    assert_equal [user.email], mail.to
    assert_equal ["noreply@hifumi.dev"], mail.from
    assert_match token, mail.body.encoded
  end
end
