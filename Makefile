
PACKAGES:=$(patsubst %.opam,%,$(notdir $(shell find src vendors -name \*.opam -print)))

active_protocol_versions := $(shell cat active_protocol_versions)
active_protocol_directories := $(shell tr -- - _ < active_protocol_versions)

current_opam_version := $(shell opam --version)
include scripts/version.sh

DOCKER_IMAGE_NAME := tezos
DOCKER_IMAGE_VERSION := latest
DOCKER_BUILD_IMAGE_NAME := $(DOCKER_IMAGE_NAME)_build
DOCKER_BUILD_IMAGE_VERSION := latest
DOCKER_BARE_IMAGE_NAME := $(DOCKER_IMAGE_NAME)-bare
DOCKER_BARE_IMAGE_VERSION := latest
DOCKER_DEBUG_IMAGE_NAME := $(DOCKER_IMAGE_NAME)-debug
DOCKER_DEBUG_IMAGE_VERSION := latest
DOCKER_DEPS_IMAGE_NAME := registry.gitlab.com/tezos/opam-repository
DOCKER_DEPS_IMAGE_VERSION := ${opam_repository_tag}
DOCKER_DEPS_MINIMAL_IMAGE_VERSION := minimal--${opam_repository_tag}
COVERAGE_REPORT := _coverage_report
MERLIN_INSTALLED := $(shell opam list merlin --installed --silent 2> /dev/null; echo $$?)

ifeq ($(filter ${opam_version}.%,${current_opam_version}),)
$(error Unexpected opam version (found: ${current_opam_version}, expected: ${opam_version}.*))
endif

current_ocaml_version := $(shell opam exec -- ocamlc -version)

.PHONY: all
all: generate_dune
ifneq (${current_ocaml_version},${ocaml_version})
	$(error Unexpected ocaml version (found: ${current_ocaml_version}, expected: ${ocaml_version}))
endif
	@dune build \
		src/bin_node/main.exe \
		src/bin_validation/main_validator.exe \
		src/bin_client/main_client.exe \
		src/bin_client/main_admin.exe \
		src/bin_signer/main_signer.exe \
		src/bin_codec/codec.exe \
		src/lib_protocol_compiler/main_native.exe \
		src/bin_snoop/main_snoop.exe \
		$(foreach p, $(active_protocol_directories), src/proto_$(p)/bin_baker/main_baker_$(p).exe) \
		$(foreach p, $(active_protocol_directories), src/proto_$(p)/bin_endorser/main_endorser_$(p).exe) \
		$(foreach p, $(active_protocol_directories), src/proto_$(p)/bin_accuser/main_accuser_$(p).exe) \
		$(foreach p, $(active_protocol_directories), src/proto_$(p)/lib_parameters/sandbox-parameters.json) \
		$(foreach p, $(active_protocol_directories), src/proto_$(p)/lib_parameters/test-parameters.json)
	@cp _build/default/src/bin_node/main.exe tezos-node
	@cp _build/default/src/bin_validation/main_validator.exe tezos-validator
	@cp _build/default/src/bin_client/main_client.exe tezos-client
	@cp _build/default/src/bin_client/main_admin.exe tezos-admin-client
	@cp _build/default/src/bin_signer/main_signer.exe tezos-signer
	@cp _build/default/src/bin_codec/codec.exe tezos-codec
	@cp _build/default/src/lib_protocol_compiler/main_native.exe tezos-protocol-compiler
	@cp _build/default/src/bin_snoop/main_snoop.exe tezos-snoop
	@for p in $(active_protocol_directories) ; do \
	   cp _build/default/src/proto_$$p/bin_baker/main_baker_$$p.exe tezos-baker-`echo $$p | tr -- _ -` ; \
	   cp _build/default/src/proto_$$p/bin_endorser/main_endorser_$$p.exe tezos-endorser-`echo $$p | tr -- _ -` ; \
	   cp _build/default/src/proto_$$p/bin_accuser/main_accuser_$$p.exe tezos-accuser-`echo $$p | tr -- _ -` ; \
	   mkdir -p src/proto_$$p/parameters ; \
	   cp _build/default/src/proto_$$p/lib_parameters/sandbox-parameters.json src/proto_$$p/parameters/sandbox-parameters.json ; \
	   cp _build/default/src/proto_$$p/lib_parameters/test-parameters.json src/proto_$$p/parameters/test-parameters.json ; \
	 done
ifeq ($(MERLIN_INSTALLED),0) # only build tooling support if merlin is installed
	@dune build @check
endif

# List protocols, i.e. directories proto_* in src with a TEZOS_PROTOCOL file.
TEZOS_PROTOCOL_FILES=$(wildcard src/proto_*/lib_protocol/TEZOS_PROTOCOL)
PROTOCOLS=$(patsubst %/lib_protocol/TEZOS_PROTOCOL,%,${TEZOS_PROTOCOL_FILES})

DUNE_INCS=$(patsubst %,%/lib_protocol/dune.inc, ${PROTOCOLS})

.PHONY: generate_dune
generate_dune: ${DUNE_INCS}

${DUNE_INCS}:: src/proto_%/lib_protocol/dune.inc: \
  src/proto_%/lib_protocol/TEZOS_PROTOCOL
	dune build @$(dir $@)/runtest_dune_template --auto-promote
	touch $@

.PHONY: all.pkg
all.pkg: generate_dune
	@dune build \
	    $(patsubst %.opam,%.install, $(shell find src vendors -name \*.opam -print))

$(addsuffix .pkg,${PACKAGES}): %.pkg:
	@dune build \
	    $(patsubst %.opam,%.install, $(shell find src vendors -name $*.opam -print))

$(addsuffix .test,${PACKAGES}): %.test:
	@dune build \
	    @$(patsubst %/$*.opam,%,$(shell find src vendors -name $*.opam))/runtest

.PHONY: doc-html
doc-html: all
	@dune build @doc
	@./tezos-client -protocol ProtoALphaALphaALphaALphaALphaALphaALphaALphaDdp3zK man -verbosity 3 -format html | sed "s#${HOME}#\$$HOME#g" > docs/api/tezos-client.html
	@./tezos-admin-client man -verbosity 3 -format html | sed "s#${HOME}#\$$HOME#g" > docs/api/tezos-admin-client.html
	@./tezos-signer man -verbosity 3 -format html | sed "s#${HOME}#\$$HOME#g" > docs/api/tezos-signer.html
	@./tezos-baker-alpha man -verbosity 3 -format html | sed "s#${HOME}#\$$HOME#g" > docs/api/tezos-baker-alpha.html
	@./tezos-endorser-alpha man -verbosity 3 -format html | sed "s#${HOME}#\$$HOME#g" > docs/api/tezos-endorser-alpha.html
	@./tezos-accuser-alpha man -verbosity 3 -format html | sed "s#${HOME}#\$$HOME#g" > docs/api/tezos-accuser-alpha.html
	@./tezos-snoop man -verbosity 3 -format html | sed "s#${HOME}#\$$HOME#g" > docs/api/tezos-snoop.html
	@mkdir -p $$(pwd)/docs/_build/api/odoc
	@rm -rf $$(pwd)/docs/_build/api/odoc/*
	@cp -r $$(pwd)/_build/default/_doc/* $$(pwd)/docs/_build/api/odoc/
	@${MAKE} -C docs html
	@echo '.toc {position: static}' >> $$(pwd)/docs/_build/api/odoc/_html/odoc.css
	@echo '.content { margin-left: 4ex }' >> $$(pwd)/docs/_build/api/odoc/_html/odoc.css
	@echo '@media (min-width: 745px) {.content {margin-left: 4ex}}' >> $$(pwd)/docs/_build/api/odoc/_html/odoc.css
	@sed -e 's/@media only screen and (max-width: 95ex) {/@media only screen and (max-width: 744px) {/' $$(pwd)/docs/_build/api/odoc/_html/odoc.css > $$(pwd)/docs/_build/api/odoc/_html/odoc.css2
	@mv $$(pwd)/docs/_build/api/odoc/_html/odoc.css2  $$(pwd)/docs/_build/api/odoc/_html/odoc.css

.PHONY: dock-html-and-linkcheck
doc-html-and-linkcheck: doc-html
	@${MAKE} -C docs all

.PHONY: coverage-report
coverage-report:
	@bisect-ppx-report html -o ${COVERAGE_REPORT} --coverage-path ${COVERAGE_OUTPUT}
	@echo "Report should be available in ${COVERAGE_REPORT}/index.html"

.PHONY: coverage-report-summary
coverage-report-summary:
	@bisect-ppx-report summary --coverage-path ${COVERAGE_OUTPUT}

.PHONY: build-sandbox
build-sandbox:
	@dune build src/bin_sandbox/main.exe
	@cp _build/default/src/bin_sandbox/main.exe tezos-sandbox

.PHONY: build-test
build-test: build-sandbox
	@dune build @buildtest

.PHONY: test-protocol-compile
test-protocol-compile:
	@dune build @runtest_compile_protocol
	@dune build @runtest_out_of_opam

.PHONY: test-unit
test-unit:
	@dune build @runtest

.PHONY: test-python
test-python: all
	@make -C tests_python all

.PHONY: test-flextesa
test-flextesa:
	@dune build @runtest_flextesa

.PHONY: test-tezt test-tezt-i test-tezt-c test-tezt-v
test-tezt:
	@dune exec tezt/tests/main.exe
test-tezt-i:
	@dune exec tezt/tests/main.exe -- --info
test-tezt-c:
	@dune exec tezt/tests/main.exe -- --commands
test-tezt-v:
	@dune exec tezt/tests/main.exe -- --verbose

.PHONY: test-code
test-code: test-protocol-compile test-unit test-flextesa test-python test-tezt

# This is `make test-code` except for flextesa (which doesn't
# play well with coverage). We allow failure (prefix "-") because we still want
# the coverage report even if an individual test happens to fail.
.PHONY: test-coverage
test-coverage:
	-@$(MAKE) test-protocol-compile
	-@$(MAKE) test-unit
	-@$(MAKE) test-python
	-@$(MAKE) test-tezt

.PHONY: lint-opam-dune
lint-opam-dune:
	@dune build @runtest_dune_template
	@./scripts/check_opam_test.sh

.PHONY: test
test: lint-opam-dune test-code

.PHONY: check-linting check-python-linting

check-linting:
	@src/tooling/lint.sh --check-ci --ignore src/tooling/test/test_not_well_formatted.ml src/tooling/test/test_not_well_formatted.mli tezt/lib/base.ml tezt/lib/base.mli
	@src/tooling/lint.sh --check-scripts
	@src/tooling/lint.sh --check-ocamlformat
	@dune build @runtest_lint

check-python-linting:
	@make -C tests_python lint_all

.PHONY: fmt
fmt:
	@src/tooling/lint.sh --format --ignore src/tooling/test/test_not_well_formatted.ml src/tooling/test/test_not_well_formatted.mli tezt/lib/base.ml tezt/lib/base.mli

.PHONY: build-deps
build-deps:
	@./scripts/install_build_deps.sh

.PHONY: build-dev-deps
build-dev-deps:
	@./scripts/install_build_deps.sh --dev

.PHONY: docker-image-build
docker-image-build:
	@docker build \
		-t $(DOCKER_BUILD_IMAGE_NAME):$(DOCKER_BUILD_IMAGE_VERSION) \
		-f build.Dockerfile \
		--build-arg BASE_IMAGE=$(DOCKER_DEPS_IMAGE_NAME) \
		--build-arg BASE_IMAGE_VERSION=$(DOCKER_DEPS_IMAGE_VERSION) \
		.

.PHONY: docker-image-debug
docker-image-debug:
	docker build \
		-t $(DOCKER_DEBUG_IMAGE_NAME):$(DOCKER_DEBUG_IMAGE_VERSION) \
		--build-arg BASE_IMAGE=$(DOCKER_DEPS_IMAGE_NAME) \
		--build-arg BASE_IMAGE_VERSION=$(DOCKER_DEPS_MINIMAL_IMAGE_VERSION) \
		--build-arg BUILD_IMAGE=$(DOCKER_BUILD_IMAGE_NAME) \
		--build-arg BUILD_IMAGE_VERSION=$(DOCKER_BUILD_IMAGE_VERSION) \
		--target=debug \
		.

.PHONY: docker-image-bare
docker-image-bare:
	@docker build \
		-t $(DOCKER_BARE_IMAGE_NAME):$(DOCKER_BARE_IMAGE_VERSION) \
		--build-arg=BASE_IMAGE=$(DOCKER_DEPS_IMAGE_NAME) \
		--build-arg=BASE_IMAGE_VERSION=$(DOCKER_DEPS_MINIMAL_IMAGE_VERSION) \
		--build-arg=BASE_IMAGE_VERSION_NON_MIN=$(DOCKER_DEPS_IMAGE_VERSION) \
		--build-arg BUILD_IMAGE=$(DOCKER_BUILD_IMAGE_NAME) \
		--build-arg BUILD_IMAGE_VERSION=$(DOCKER_BUILD_IMAGE_VERSION) \
		--target=bare \
		.

.PHONY: docker-image-minimal
docker-image-minimal:
	@docker build \
		-t $(DOCKER_IMAGE_NAME):$(DOCKER_IMAGE_VERSION) \
		--build-arg=BASE_IMAGE=$(DOCKER_DEPS_IMAGE_NAME) \
		--build-arg=BASE_IMAGE_VERSION=$(DOCKER_DEPS_MINIMAL_IMAGE_VERSION) \
		--build-arg=BASE_IMAGE_VERSION_NON_MIN=$(DOCKER_DEPS_IMAGE_VERSION) \
		--build-arg BUILD_IMAGE=$(DOCKER_BUILD_IMAGE_NAME) \
		--build-arg BUILD_IMAGE_VERSION=$(DOCKER_BUILD_IMAGE_VERSION) \
		.

.PHONY: docker-image
docker-image: docker-image-build docker-image-debug docker-image-bare docker-image-minimal

.PHONY: install
install:
	@dune build @install
	@dune install

.PHONY: uninstall
uninstall:
	@dune uninstall

.PHONY: coverage-clean
coverage-clean:
	@-rm -Rf ${COVERAGE_OUTPUT}/*.coverage ${COVERAGE_REPORT}

.PHONY: clean
clean: coverage-clean
	@-dune clean
	@-rm -f \
		tezos-node \
		tezos-validator \
		tezos-client \
		tezos-signer \
		tezos-admin-client \
		tezos-codec \
		tezos-protocol-compiler \
		tezos-snoop \
		tezos-sandbox \
	  $(foreach p, $(active_protocol_versions), tezos-baker-$(p) tezos-endorser-$(p) tezos-accuser-$(p)) \
	  $(foreach p, $(active_protocol_directories), src/proto_$(p)/parameters/sandbox-parameters.json src/proto_$(p)/parameters/test-parameters.json)
	@-${MAKE} -C docs clean
	@-${MAKE} -C tests_python clean
	@-rm -f docs/api/tezos-{baker,endorser,accuser}-alpha.html docs/api/tezos-{admin-,}client.html docs/api/tezos-signer.html
