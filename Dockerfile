# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t hifumi_dev .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name hifumi_dev hifumi_dev

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.2
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages. Includes docker-ce-cli (the generator talks to the
# host Docker daemon over the bind-mounted socket) and build-essential
# (workspaces' bundle install compiles native extensions for bigdecimal/json,
# which RubyGems doesn't ship precompiled — see ExecuteInstructionJob#init_rails_app).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips sqlite3 ca-certificates gnupg lsb-release build-essential git libyaml-dev pkg-config && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y docker-ce-cli && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install the Claude Code CLI binary. Roast 1.1.0's only agent providers are
# :claude and :pi, and the :claude provider spawns a `claude` binary via
# Open3. bin/roast-openrouter sets ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN so
# the CLI sends every request to OpenRouter — no traffic hits Anthropic, no
# subscription is involved; the CLI is just an HTTP client speaking the
# Anthropic Messages API which OpenRouter implements. The CLI is only used
# at *generation* time inside this container — it never ships with users'
# apps. Replacing this with a direct-API Roast provider is a Phase 5
# candidate.
#
# The CLI refuses --dangerously-skip-permissions as root, so we:
#   1. install the binary as root (default install path is /root/.local/...)
#   2. relocate it to a world-readable path
#   3. create a `generator` non-root user
#   4. wrap `claude` so root invocations re-exec it as `generator` via runuser
#
# Runtime callers (ExecuteInstructionJob → bin/roast-openrouter → roast →
# Open3.popen3 "claude") still run as root, but the CLI binary itself runs
# as `generator`, which the CLI accepts.
RUN useradd -m -u 1000 -s /bin/bash generator && \
    curl -fsSL https://claude.ai/install.sh | bash && \
    mv /root/.local/share/claude /opt/claude && \
    chmod -R a+rX /opt/claude && \
    rm /root/.local/bin/claude && \
    printf '%s\n' \
      '#!/bin/sh' \
      'real=/opt/claude/versions/$(ls -1 /opt/claude/versions | sort -V | tail -1)' \
      'if [ "$(id -u)" -eq 0 ]; then' \
      '  HOME=/home/generator exec runuser -p -u generator -- "$real" "$@"' \
      'else' \
      '  exec "$real" "$@"' \
      'fi' \
      > /usr/local/bin/claude && \
    chmod +x /usr/local/bin/claude && \
    git config --system --add safe.directory '*' && \
    git config --system user.name 'Hifumi' && \
    git config --system user.email 'contact@hifumi.dev'

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

# All build-time apt packages (build-essential, git, libvips, libyaml-dev,
# pkg-config) are now in the base layer so the runtime stage can compile
# workspace gems too — nothing extra needed here.

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile




# Final stage for app image
FROM base

# Generator runs as root inside the container — bind-mounted Docker socket is
# effective root on the host anyway, and root simplifies workspace permissions
# (UID alignment with the host bind mount path).

# Copy built artifacts: gems, application
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
