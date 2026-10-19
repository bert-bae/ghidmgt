# Disposable sandbox for the ghid test suite.
#
# ghid rewrites ~/.gitconfig, ~/.ssh/config and shell rc files, so the suite
# never runs on a real machine. `make test` builds this image with the source
# copied in (no bind mounts, so nothing can write back to the host) and runs
# it as an unprivileged user with networking and capabilities disabled.
#
#   BASE=debian:bookworm-slim   bash 5, GNU userland, shellcheck (default)
#   BASE=bash:3.2               the bash macOS ships, on Alpine/BusyBox
ARG BASE=debian:bookworm-slim
FROM ${BASE}

RUN set -eu; \
    if command -v apt-get >/dev/null 2>&1; then \
        apt-get update; \
        apt-get install -y --no-install-recommends git zsh shellcheck; \
        rm -rf /var/lib/apt/lists/*; \
        useradd --create-home tester; \
    else \
        apk add --no-cache git zsh; \
        adduser -D tester; \
    fi

ENV GHID_TEST_SANDBOX=1 NO_COLOR=1
COPY --chown=tester:tester . /src
USER tester
WORKDIR /src
ENTRYPOINT []
CMD ["bash", "tests/run.sh"]
