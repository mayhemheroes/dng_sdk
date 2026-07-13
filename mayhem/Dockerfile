# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for dng_sdk — builds the Adobe DNG SDK + its libFuzzer harnesses on
# top of the org C/C++ base (clang/llvm + libFuzzer + sanitizers + build contract).
FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# The SDK links libjpeg + zlib; zlib-dev ships in the base, libjpeg-dev does not.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends libjpeg-dev \
    && rm -rf /var/lib/apt/lists/*
USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
