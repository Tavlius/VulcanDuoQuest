# The one test environment. tests/docker.sh builds this file for local runs and the
# GitHub Actions test job builds the same file, so local and CI results can't differ.
# Everything is pinned: the base image by digest, luacheck by version, and the BigWigs
# packager by commit and checksum (the same release.sh that BigWigsMods/packager@v2 runs).
FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      lua5.1 liblua5.1-0-dev luarocks build-essential python3 git zip unzip curl jq ca-certificates \
 && luarocks install luacheck 1.2.0 \
 && rm -rf /var/lib/apt/lists/*
ARG PACKAGER_COMMIT=e50a250f8705041e40f2fa1ddcb280a686d65aa0
ARG PACKAGER_SHA256=59b15a8d851b09e6d0fdec702aec91331b9b49d84dbe778da6c621b48f268703
RUN curl -fsSL "https://raw.githubusercontent.com/BigWigsMods/packager/${PACKAGER_COMMIT}/release.sh" \
      -o /usr/local/bin/release.sh \
 && echo "${PACKAGER_SHA256}  /usr/local/bin/release.sh" | sha256sum -c - \
 && chmod +x /usr/local/bin/release.sh
