from typing import List
import pytest
from tools import utils, constants
from client.client import Client
from . import protocol


TRANSFER_AMOUNT = 500


# TODO  test doesn't pass with n=2 (--bootstrap-treshold?)
@pytest.mark.multinode
@pytest.mark.parametrize("clients", [3], indirect=True)
@pytest.mark.incremental
class TestManualBaking:
    """
    For n nodes in sandboxed mode, tests:
    . injection of protocol alpha
    . check inclusion of transfer and endorsement operations
    """

    def test_level(self, clients: List[Client]):
        level = 1
        for client in clients:
            assert utils.check_level(client, level)

    def test_bake_and_check_level(self, clients: List[Client]):
        level = 2
        for i in range(1, 6):
            account = f'bootstrap{i}'
            client_i = level % len(clients)
            utils.bake(clients[client_i], account)
            for client in clients:
                assert utils.check_level(client, level)
            level += 1

    def test_endorse(self, clients: List[Client], session: dict):
        endorse = clients[2 % len(clients)].endorse('bootstrap3')
        session["endorse_hash"] = endorse.operation_hash

    def test_transfer(self, clients: List[Client], session: dict):
        client_id = 3 % len(clients)
        transfer = clients[client_id].transfer(
            TRANSFER_AMOUNT, 'bootstrap1', 'bootstrap3'
        )
        session["transfer_hash"] = transfer.operation_hash
        session["transfer_fees"] = transfer.fees

    def test_mempool_contains_endorse_and_transfer(
        self, clients: List[Client], session
    ):
        endorse_hash = session["endorse_hash"]
        transfer_hash = session["transfer_hash"]
        operation_hashes = [endorse_hash, transfer_hash]
        for client in clients:
            assert utils.check_mempool_contains_operations(
                client, operation_hashes
            )

    def test_bake(self, clients: List[Client]):
        utils.bake(clients[3 % len(clients)], 'bootstrap4')

    def test_block_contains_endorse_and_transfer(
        self, clients: List[Client], session
    ):
        endorse_hash = session["endorse_hash"]
        transfer_hash = session["transfer_hash"]
        operation_hashes = [endorse_hash, transfer_hash]
        for client in clients:
            assert utils.check_block_contains_operations(
                client, operation_hashes
            )

    def test_balance(self, clients: List[Client], session):
        baker_id = constants.IDENTITIES['bootstrap1']['identity']
        bal = clients[0].get_balance(baker_id)
        parameters = protocol.PARAMETERS
        initial_amount = int(parameters["bootstrap_accounts"][0][1])
        deposit = int(parameters["block_security_deposit"])
        tx_fee = session['transfer_fees']
        assert (
            bal
            == (initial_amount - deposit) / 1000000 - tx_fee - TRANSFER_AMOUNT
        )
