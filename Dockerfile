######################## build ###############################
FROM ubuntu:20.04 as builder
ENV DEBIAN_FRONTEND=noninteractive
ENV OPAMSOLVERTIMEOUT=60000
RUN apt-get update
RUN apt-get install -y build-essential autoconf git m4 unzip rsync curl libev-dev libgmp-dev pkg-config libhidapi-dev libffi-dev zlib1g-dev wget libcap2

ADD . T4L3NT
WORKDIR T4L3NT

RUN wget https://sh.rustup.rs/rustup-init.sh && chmod +x rustup-init.sh && \
  ./rustup-init.sh --profile minimal --default-toolchain 1.44.0 -y
RUN wget https://raw.githubusercontent.com/ocaml/opam/master/shell/install.sh && chmod +x install.sh && \
  ./install.sh --download-only --version 2.0.9

ENV PATH="${HOME}/.cargo/bin:${PATH}"

RUN mv opam-2.0.9-x86_64-linux /usr/local/bin/opam
RUN chmod a+x /usr/local/bin/opam
RUN opam init --bare --disable-sandboxing
SHELL ["/bin/bash", "-c", "-l"]
RUN make build-deps
RUN eval $(opam env) && make
RUN mkdir /_scripts && mkdir /_bin
RUN cp -a scripts/docker/entrypoint.sh /_bin/ && \
  cp -a scripts/docker/entrypoint.inc.sh /_bin/ && \
  cp scripts/alphanet_version /_scripts/ && \
  cp src/bin_client/bash-completion.sh /_scripts/ && \
  cp active_protocol_versions /_scripts/

RUN wget https://raw.githubusercontent.com/zcash/zcash/master/zcutil/fetch-params.sh && chmod +x fetch-params.sh && \
  ./fetch-params.sh
RUN mv $HOME/.zcash-params /_zcash-params

######################## final ###############################

FROM ubuntu:latest as final

ARG BAKER_ID=${BAKER_ID}
ENV BAKER_ID=${BAKER_ID}
ENV BAKER_NAME=${BAKER_NAME:-baker}

VOLUME ["/home/tlnt"]

RUN apt-get update && \
  apt-get install -y libev-dev libgmp-dev libhidapi-dev netbase supervisor && \
  apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN mkdir -p /var/run/tezos/node /var/run/tezos/client /usr/local/share/zcash-params

COPY --from=builder /_scripts/* /usr/local/share/tezos/
COPY --from=builder /_bin/* /usr/local/bin/
COPY --from=builder /_zcash-params/* /usr/local/share/zcash-params/
COPY --from=builder /T4L3NT/tlnt-node /usr/local/bin/
COPY --from=builder /T4L3NT/tlnt-accuser-* /usr/local/bin/
COPY --from=builder /T4L3NT/tlnt-admin-client /usr/local/bin/
COPY --from=builder /T4L3NT/tlnt-baker-* /usr/local/bin/
COPY --from=builder /T4L3NT/tlnt-client /usr/local/bin/
COPY --from=builder /T4L3NT/tlnt-endorser-* /usr/local/bin/
COPY --from=builder /T4L3NT/tlnt-protocol-compiler /usr/local/bin/
COPY --from=builder /T4L3NT/tlnt-signer /usr/local/bin/

# Override the official entrypoint with our own
COPY docker/entrypoint.sh /usr/local/bin
COPY docker/setup.sh /usr/local/bin
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/setup.sh

RUN useradd -u 1000 -m tlnt

COPY docker/tlnt-baker /usr/local/bin
COPY docker/tlnt-endorser /usr/local/bin
COPY docker/tlnt-accuser /usr/local/bin
COPY docker/tlnt-baker-next /usr/local/bin
COPY docker/tlnt-endorser-next /usr/local/bin
COPY docker/tlnt-accuser-next /usr/local/bin
RUN chmod +x /usr/local/bin/tlnt-*

COPY --chown=tlnt docker/talent-chain-params.json /tmp/chain.json
COPY --chown=tlnt docker/config.json /tmp/config.json

# Setup supervisor for other subprocesses
COPY docker/supervisor/tlnt-node.conf /etc/supervisor/conf.d/
COPY docker/supervisor/baker.conf /etc/supervisor/conf.d/
COPY docker/supervisor/endorser.conf /etc/supervisor/conf.d/
COPY docker/supervisor/accuser.conf /etc/supervisor/conf.d/
COPY docker/supervisor/baker-next.conf /etc/supervisor/conf.d/
COPY docker/supervisor/endorser-next.conf /etc/supervisor/conf.d/
COPY docker/supervisor/accuser-next.conf /etc/supervisor/conf.d/
COPY docker/supervisor/tlnt-node-stdout-log.conf /etc/supervisor/conf.d/

RUN chown tlnt /var/log/supervisor /var/run

USER tlnt
ENV USER=tlnt
WORKDIR /home/tlnt

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
