#!/bin/sh
# Install smoke test: reproduces the README install steps inside the official
# fluent/fluentd Debian image to verify the mysql2 native extension actually
# builds and the plugins load. Guards against the "Failed to build gem native
# extension" class of breakage reported in #43 / #16 / #35.
set -eux

GEM_FILE="${GEM_FILE:-/workspace/pkg/fluent-plugin-mysql-replicator.gem}"

# Build toolchain + MySQL client development headers (the bit users forget).
apt-get update
apt-get install -y build-essential default-libmysqlclient-dev

# Installing the gem compiles the mysql2 native extension; this fails loudly
# if the client headers are missing, which is exactly what we want to catch.
gem install "$GEM_FILE"

# Confirm the installed plugins (and the mysql2 native extension) load at runtime.
ruby "$(dirname "$0")/verify_plugins_load.rb"
