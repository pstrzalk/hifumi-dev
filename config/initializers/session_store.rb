# Session cookie hardening (multi-tenant isolation).
#
# In production the generator shares its registrable domain (hifumi.dev) with the
# untrusted, user-built preview apps served at <id>.preview.hifumi.dev. A preview
# runs arbitrary HTML/JS and can set a cookie scoped to `Domain=hifumi.dev`, which
# the browser would deliver to the generator — letting a malicious preview shadow
# ("toss") the generator's own session cookie onto a victim (session fixation /
# login CSRF).
#
# The `__Host-` cookie-name prefix closes this: the browser REJECTS any
# `__Host-`-named cookie that carries a Domain attribute (or a non-"/" Path, or no
# Secure flag). A subdomain therefore cannot set a `__Host-`-named cookie for the
# parent, so the generator's session cookie becomes un-shadowable from any preview.
#
# `__Host-` mandates Secure, so it only works over HTTPS. Dev runs on
# http://localhost where a Secure cookie is never sent, so keep the plain
# (current) cookie name there — switching only production also avoids changing the
# dev cookie name.
if Rails.env.production?
  Rails.application.config.session_store :cookie_store,
    key: "__Host-hifumi_dev_session",
    secure: true,
    same_site: :lax,
    path: "/" # the __Host- prefix mandates Path=/ (also the cookie_store default)
else
  Rails.application.config.session_store :cookie_store,
    key: "_hifumi_dev_session",
    same_site: :lax
end
