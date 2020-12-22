ARG BASE_IMAGE=registry.gitlab.com/tezos/opam-repository
ARG BASE_IMAGE_VERSION
FROM ${BASE_IMAGE}:${BASE_IMAGE_VERSION}
# do not move the ARG below above the FROM or it gets erased
ARG GIT_SHORTREF
WORKDIR /home/tezos
RUN mkdir -p /home/tezos/tezos/scripts
COPY --chown=tezos:nogroup Makefile tezos
COPY --chown=tezos:nogroup active_protocol_versions tezos
COPY --chown=tezos:nogroup dune tezos
COPY --chown=tezos:nogroup scripts/version.sh tezos/scripts/
COPY --chown=tezos:nogroup src tezos/src
COPY --chown=tezos:nogroup vendors tezos/vendors
ENV GIT_SHORTREF=${GIT_SHORTREF}
RUN opam exec -- make -C tezos all build-test
