# Ubuntu OS Pipa image builder
#
# Usage:
#   make builder          Build the Docker builder image
#   make image            Build GNOME + Plasma disk images
#   make clean            Remove generated images

SHELL := /bin/bash
BUILDER_IMAGE := ubuntu-pipa-builder
OUTPUT_DIR := output

BUILD_GIT_REV ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_VARIANTS ?= gnome plasma
PIPA_PKGS_URL ?= https://thespider2.github.io/pipa-pkgs/repo/ubuntu/

DOCKER_RUN := docker run --rm --privileged \
	-v "$(CURDIR)/$(OUTPUT_DIR):/build/output" \
	-v /dev:/dev \
	-e BUILD_GIT_REV="$(BUILD_GIT_REV)" \
	-e BUILD_VARIANTS="$(BUILD_VARIANTS)" \
	-e PIPA_PKGS_URL="$(PIPA_PKGS_URL)" \
	$(BUILDER_IMAGE)

.PHONY: help builder image clean check-docker

help:
	@echo "Ubuntu OS Pipa image builder"
	@echo
	@echo "Targets:"
	@echo "  builder   Build the Docker builder image"
	@echo "  image     Build GNOME and Plasma disk images"
	@echo "  clean     Remove generated images"
	@echo
	@echo "Environment variables:"
	@echo "  BUILD_VARIANTS   Space-separated variants (default: gnome plasma)"
	@echo "  PIPA_PKGS_URL    apt repo URL for pipa packages"
	@echo "  BUILD_GIT_REV    Git revision stamped into build metadata"

check-docker:
	@command -v docker >/dev/null || { echo "docker is required but not installed."; exit 1; }

builder: check-docker
	docker build -t $(BUILDER_IMAGE) .

$(OUTPUT_DIR):
	mkdir -p $(OUTPUT_DIR)

image: builder $(OUTPUT_DIR)
	$(DOCKER_RUN)

clean:
	rm -rf $(OUTPUT_DIR)/*
