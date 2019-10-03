import time
import pytest
from tools import utils, constants


BAKE_ARGS = ['--max-priority', '512', '--minimal-timestamp']
NUM_NODES = 3
PARAMS = ['--connections', '500']


@pytest.mark.multinode
@pytest.mark.incremental
class TestDoubleEndorsement:
    """Constructs a double endorsement, and build evidence."""

    def test_init(self, sandbox):
        for i in range(NUM_NODES):
            sandbox.add_node(i, params=PARAMS)
        utils.activate_alpha(sandbox.client(0))
        sandbox.client(0).bake('bootstrap1', BAKE_ARGS)

    def test_level(self, sandbox):
        level = 2
        for client in sandbox.all_clients():
            assert utils.check_level(client, level)

    def test_terminate_nodes_1_and_2(self, sandbox):
        sandbox.node(1).terminate()
        sandbox.node(2).terminate()

    def test_bake_node_0(self, sandbox):
        """Client 0 bakes block A at level 3, not communicated to 1 and 2"""
        """Inject an endorsement to ensure a different hash"""
        sandbox.client(0).endorse('bootstrap1')
        sandbox.client(0).bake('bootstrap1', BAKE_ARGS)

    def test_endorse_node_0(self, sandbox, session):
        """bootstrap1 builds an endorsement for block A"""
        client = sandbox.client(0)
        client.endorse('bootstrap1')
        mempool = client.get_mempool()
        endorsement = mempool['applied'][0]
        session['endorsement1'] = endorsement

    def test_terminate_node_0(self, sandbox):
        sandbox.node(0).terminate()

    def test_restart_node_2(self, sandbox):
        sandbox.node(2).run()
        time.sleep(1)

    def test_bake_node_2(self, sandbox):
        """Client 2 bakes block B at level 3, not communicated to 0 and 1"""
        sandbox.client(2).bake('bootstrap1', BAKE_ARGS)

    def test_endorse_node_2(self, sandbox, session):
        """bootstrap1 builds an endorsement for block B"""
        client = sandbox.client(2)
        client.endorse('bootstrap1')
        mempool = client.get_mempool()
        endorsement = mempool['applied'][0]
        session['endorsement2'] = endorsement
        sandbox.client(2).endorse('bootstrap2')

    def test_restart_all(self, sandbox):
        sandbox.node(0).run()
        sandbox.node(1).run()
        time.sleep(1)

    def test_check_level(self, sandbox):
        """All nodes are at level 3, head is either block A or B"""
        level = 3
        for client in sandbox.all_clients():
            assert utils.check_level(client, level)

    def test_forge_accusation(self, sandbox, session):
        """Forge and inject a double endorsement evidence operation"""
        client = sandbox.client(1)
        head_hash = client.get_head()['hash']

        def transform_endorsement(end):
            return {'branch': end['branch'],
                    'operations': end['contents'][0],
                    'signature': end['signature']}
        endorsement1 = transform_endorsement(session['endorsement1'])
        endorsement2 = transform_endorsement(session['endorsement2'])
        operation = {'branch': head_hash,
                     'contents': [{'kind': 'double_endorsement_evidence',
                                   'op1': endorsement1,
                                   'op2': endorsement2}]}

        path_forge_operation = ('/chains/main/blocks/head/helpers/forge/'
                                'operations')
        operation_hex_string = client.rpc('post',
                                          path_forge_operation,
                                          data=operation)
        assert isinstance(operation_hex_string, str)
        sender_sk_long = constants.IDENTITIES['bootstrap1']['secret']
        sender_sk = sender_sk_long[len('unencrypted:'):]
        signed_op = utils.sign_operation(operation_hex_string, sender_sk)
        op_hash = client.rpc('post', 'injection/operation', signed_op)
        assert isinstance(op_hash, str)
        session['operation'] = op_hash

    def test_operation_applied(self, sandbox, session):
        """Check operation is in mempool"""
        client = sandbox.client(1)
        assert utils.check_mempool_contains_operations(client,
                                                       [session['operation']])
