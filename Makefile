# ghid rewrites ~/.gitconfig, ~/.ssh/config and shell rc files, so nothing in
# here executes it on your machine: every target runs in a throwaway container
# with no network, no host mounts and no capabilities. See tests/Dockerfile.
DOCKER ?= docker
IMAGE  ?= ghid-test
SANDBOX = $(DOCKER) run --rm --network none --cap-drop ALL --security-opt no-new-privileges

.PHONY: test test-bash5 test-bash3 lint image-bash5 image-bash3

## test: run the suite under bash 5 (Debian) and bash 3.2 (the version macOS ships)
test: test-bash5 test-bash3

test-bash5: image-bash5
	$(SANDBOX) $(IMAGE):bash5

test-bash3: image-bash3
	$(SANDBOX) $(IMAGE):bash3

## lint: shellcheck every script
lint: image-bash5
	$(SANDBOX) $(IMAGE):bash5 shellcheck --severity=warning ghid install.sh tests/run.sh

image-bash5:
	$(DOCKER) build --quiet --file tests/Dockerfile --tag $(IMAGE):bash5 . >/dev/null

image-bash3:
	$(DOCKER) build --quiet --file tests/Dockerfile --build-arg BASE=bash:3.2 --tag $(IMAGE):bash3 . >/dev/null
