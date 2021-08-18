######################## build ###############################
FROM ubuntu:latest as builder
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update
RUN apt-get install -y build-essential autoconf git m4 unzip rsync curl libev-dev libgmp-dev pkg-config libhidapi-dev libffi-dev
RUN apt-get install -y wget libcap2
RUN wget http://security.ubuntu.com/ubuntu/pool/universe/b/bubblewrap/bubblewrap_0.2.1-1_amd64.deb
RUN dpkg -i ./bubblewrap_0.2.1-1_amd64.deb

ADD T4L3NT tezos
WORKDIR tezos

RUN wget https://sh.rustup.rs/rustup-init.sh && chmod +x rustup-init.sh && \
  ./rustup-init.sh --profile minimal --default-toolchain 1.44.0 -y
RUN wget https://raw.githubusercontent.com/ocaml/opam/master/shell/install.sh && chmod +x install.sh && \
  ./install.sh --download-only

ENV PATH="${HOME}/.cargo/bin:${PATH}"

RUN mv opam-2.0.8-x86_64-linux /usr/local/bin/opam
RUN chmod a+x /usr/local/bin/opam
RUN opam init --comp=4.09.1 --disable-sandboxing
RUN opam update
RUN cat ${HOME}/.cargo/env
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

VOLUME ["/home/tezos"]

RUN apt-get update && \
  apt-get install -y libev-dev libgmp-dev libhidapi-dev netbase supervisor sudo && \
  apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN mkdir -p /var/run/tezos/node /var/run/tezos/client /usr/local/share/zcash-params

COPY --from=builder /_scripts/* /usr/local/share/tezos/
COPY --from=builder /_bin/* /usr/local/bin/
COPY --from=builder /_zcash-params/* /usr/local/share/zcash-params/
COPY --from=builder /tezos/tlnt-node /usr/local/bin/
COPY --from=builder /tezos/tlnt-accuser-* /usr/local/bin/
COPY --from=builder /tezos/tlnt-admin-client /usr/local/bin/
COPY --from=builder /tezos/tlnt-baker-* /usr/local/bin/
COPY --from=builder /tezos/tlnt-client /usr/local/bin/
COPY --from=builder /tezos/tlnt-endorser-* /usr/local/bin/
COPY --from=builder /tezos/tlnt-protocol-compiler /usr/local/bin/
COPY --from=builder /tezos/tlnt-signer /usr/local/bin/

# Override the official entrypoint with our own
COPY entrypoint.sh /usr/local/bin
COPY conf/setup_keys.sh /usr/local/bin
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/setup_keys.sh

RUN useradd -u 1000 -m tlnt
RUN adduser tlnt sudo
RUN echo "tlnt ALL=(ALL) NOPASSWD:SETENV: /usr/bin/supervisord" | tee /etc/sudoers

COPY conf/tlnt-baker /usr/local/bin
COPY conf/tlnt-endorser /usr/local/bin
COPY conf/tlnt-accuser /usr/local/bin
#COPY conf/tlnt-baker-next /usr/local/bin
#COPY conf/tlnt-endorser-next /usr/local/bin
#COPY conf/tlnt-accuser-next /usr/local/bin
RUN chmod +x /usr/local/bin/tlnt-*

COPY --chown=tlnt ./conf/talent-chain-params.json /tmp/chain.json
COPY --chown=tlnt ./conf/config.json /tmp/config.json

# Setup supervisor for other subprocesses
COPY conf/baker.conf /etc/supervisor/conf.d/
COPY conf/endorser.conf /etc/supervisor/conf.d/
COPY conf/accuser.conf /etc/supervisor/conf.d/
#COPY conf/baker-next.conf /etc/supervisor/conf.d/
#COPY conf/endorser-next.conf /etc/supervisor/conf.d/
#COPY conf/accuser-next.conf /etc/supervisor/conf.d/

USER tlnt
ENV USER=tlnt
WORKDIR /home/tlnt

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
