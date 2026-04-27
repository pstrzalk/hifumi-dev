ARG BASE_TAG=preview-base:latest
FROM ${BASE_TAG}

WORKDIR /app

COPY . .

# Install any gems added by revisions on top of the skeleton's pre-bundled set.
RUN bundle install

# Pre-build Tailwind CSS (dev mode + Propshaft serves the result).
# No `|| true` — a CSS build failure must surface as a build failure.
RUN bin/rails tailwindcss:build

ENV RAILS_ENV=development \
    RAILS_LOG_TO_STDOUT=1 \
    PORT=3000

EXPOSE 3000

# Entrypoint ships with the workspace via Step 1's skeleton-overlay.
ENTRYPOINT ["/app/bin/preview-entrypoint"]
