"""Hooks and fixtures.

A fixture defines code to be run before and after a (sequence of) test,
E.g. start and stop a server. The fixture is simply specified as a parameter
in the test function, and the yielded values is then accessible with this
parameter.
"""
import os
import pytest
from pytest_regtest import register_converter_pre, deregister_converter_pre, \
    _std_conversion
from launchers.sandbox import Sandbox, SandboxMultiBranch
from tools import constants, paths, utils
from tools.client_regression import ClientRegression


@pytest.fixture(scope="session", autouse=True)
def sanity_check(request):
    """Sanity checks before running the tests."""
    log_dir = request.config.getoption("--log-dir")
    if not (log_dir is None or os.path.isdir(log_dir)):
        print(f"{log_dir} doesn't exist")
        pytest.exit(1)


@pytest.fixture(scope="session")
def log_dir(request):
    """Retrieve user-provided logging directory on the command line."""
    yield request.config.getoption("--log-dir")


@pytest.fixture(scope="class")
def session():
    """Dictionary to store data between tests."""
    yield {}


def pytest_runtest_makereport(item, call):
    # hook for incremental test
    # from https://docs.pytest.org/en/latest/example/simple.html
    if "incremental" in item.keywords:
        if call.excinfo is not None:
            parent = item.parent
            # TODO can we do without this hack?
            parent._previousfailed = item  # pylint: disable=protected-access


def pytest_runtest_setup(item):
    if "incremental" in item.keywords:
        previousfailed = getattr(item.parent, "_previousfailed", None)
        if previousfailed is not None:
            pytest.xfail("previous test failed (%s)" % previousfailed.name)


def pytest_addoption(parser):
    parser.addoption(
        "--log-dir", action="store", help="specify log directory"
    )


DEAD_DAEMONS_WARN = '''
It seems some daemons terminated unexpectingly, or didn't launch properly.
You can investigate daemon logs by running this test using the
`--log-dir=LOG_DIR` option.'''


@pytest.fixture(scope="class")
def sandbox(log_dir):
    """Sandboxed network of nodes.

    Nodes, bakers and endorsers are added/removed dynamically."""
    # log_dir is None if not provided on command-line
    with Sandbox(paths.TEZOS_HOME,
                 constants.IDENTITIES,
                 constants.GENESIS_PK,
                 log_dir=log_dir) as sandbox:
        yield sandbox
        assert sandbox.are_daemons_alive(), DEAD_DAEMONS_WARN


@pytest.fixture(scope="class")
def client(sandbox):
    """One node with protocol alpha."""
    sandbox.add_node(0, params=constants.NODE_PARAMS)
    client = sandbox.client(0)
    utils.activate_alpha(client)
    yield client


@pytest.fixture(scope="class")
def client_regtest_bis(sandbox):
    """One node with protocol alpha, regression test enabled."""
    def reg_client_factory(client_path: str,
                           admin_client_path: str,
                           host: str = '127.0.0.1',
                           base_dir: str = None,
                           rpc_port: int = 8732,
                           use_tls: int = False,
                           disable_disclaimer: bool = True):
        client = ClientRegression(client_path,
                                  admin_client_path,
                                  host,
                                  base_dir,
                                  rpc_port,
                                  use_tls,
                                  disable_disclaimer)
        return client

    sandbox.add_node(1, client_factory=reg_client_factory,
                     params=constants.NODE_PARAMS)
    client = sandbox.client(1)
    utils.activate_alpha(client)
    yield client


@pytest.fixture(scope="function")
def client_regtest(client_regtest_bis, regtest):
    """The client for one node with protocol alpha, with a function level
regression test fixture."""
    deregister_converter_pre(_std_conversion)
    client_regtest_bis.set_regtest(regtest)
    register_converter_pre(utils.client_always_output_converter)
    yield client_regtest_bis
    deregister_converter_pre(utils.client_always_output_converter)


@pytest.fixture(scope="function")
def client_regtest_scrubbed(client_regtest):
    """One node with protocol alpha, regression test and scrubbing enabled."""
    register_converter_pre(utils.client_output_converter)
    yield client_regtest
    deregister_converter_pre(utils.client_output_converter)


@pytest.fixture(scope="class")
def clients(sandbox, request):
    """N node with protocol alpha. Parameterized by the number of nodes.

    Number of nodes is specified as a class annotation.
    @pytest.mark.parametrize('clients', [N], indirect=True)
    """
    assert request.param is not None
    num_nodes = request.param
    for i in range(num_nodes):
        # Large number may increases peers connection time
        sandbox.add_node(i, params=constants.NODE_PARAMS)
    utils.activate_alpha(sandbox.client(0))
    clients = sandbox.all_clients()
    for client in clients:
        proto = constants.ALPHA
        assert utils.check_protocol(client, proto)
    yield clients


@pytest.fixture(scope="class")
def sandbox_multibranch(log_dir, request):
    """Multi-branch sandbox fixture. Parameterized by map of branches.

    This fixture is identical to `sandbox` except that each node_id is
    mapped to a pair (git revision, protocol version). For instance,
    suppose a mapping:

      MAP = { 0: ('zeronet', 'alpha'), 1:('mainnet', '003-PsddFKi3'),
              2: ('alphanet', '003-PsddFKi3' }

    If we annotate the class test as follows.
    @pytest.mark.parametrize('sandbox_multibranch', [MAP], indirect=True)

    The executables (node, baker, endorser)
    - for node_id 0 will be looked up in `TEZOS_BINARY/zeronet`,
    - for node_id 1 will be looked up in `TEZOS_BINARY/mainnet` and so on...

    baker and endorser will use the specified protocol version, according
    to the tezos executables naming conventions.
    """
    if paths.TEZOS_BINARIES is None:
        pytest.skip()
    branch_map = request.param
    assert branch_map is not None
    num_peers = max(branch_map) + 1

    with SandboxMultiBranch(paths.TEZOS_BINARIES,
                            constants.IDENTITIES,
                            constants.GENESIS_PK,
                            num_peers=num_peers,
                            log_dir=log_dir,
                            branch_map=branch_map) as sandbox:
        yield sandbox
        # this assertion checks that daemons (baker, endorser, node...) didn't
        # fail unexpected.
        assert sandbox.are_daemons_alive(), DEAD_DAEMONS_WARN


def pytest_collection_modifyitems(config, items):
    '''Adapted from pytest-fixture-marker: adds the regression marker
    to all tests that use the regtest fixture.
    '''
    # pylint: disable=unused-argument

    for item in items:
        if 'regtest' in item.fixturenames:
            item.add_marker('regression')
