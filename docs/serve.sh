#!/bin/bash
# Run Jekyll locally using Docker — no Ruby install needed
# Usage: ./serve.sh
docker run --rm \
  -v "$(pwd):/srv/jekyll" \
  -w /srv/jekyll \
  -p 4000:4000 \
  ruby:3.2 \
  bash -c "gem install bundler -q && bundle install -q && bundle exec jekyll serve --host 0.0.0.0"
