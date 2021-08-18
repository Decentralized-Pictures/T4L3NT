import os
import re
import json
import itertools
from typing import List, Union, Any
import pytest

from client.client import Client
from tools import utils
from tools.constants import IDENTITIES
from tools.utils import originate
from .contract_paths import (
    CONTRACT_PATH,
    ILLTYPED_CONTRACT_PATH,
    all_contracts,
    all_legacy_contracts,
)


@pytest.mark.contract
@pytest.mark.incremental
class TestManager:
    def test_manager_origination(self, client: Client, session: dict):
        path = os.path.join(CONTRACT_PATH, 'entrypoints', 'manager.tz')
        pubkey = IDENTITIES['bootstrap2']['identity']
        originate(client, session, path, f'"{pubkey}"', 1000)
        originate(
            client, session, path, f'"{pubkey}"', 1000, contract_name="manager2"
        )

    def test_delegatable_origination(self, client: Client, session: dict):
        path = os.path.join(
            CONTRACT_PATH, 'entrypoints', 'delegatable_target.tz'
        )
        pubkey = IDENTITIES['bootstrap2']['identity']
        originate(
            client, session, path, f'Pair "{pubkey}" (Pair "hello" 45)', 1000
        )

    def test_target_with_entrypoints_origination(self, client: Client, session):
        path = os.path.join(
            CONTRACT_PATH, 'entrypoints', 'big_map_entrypoints.tz'
        )
        originate(
            client, session, path, 'Pair {} {}', 1000, contract_name='target'
        )

    def test_target_without_entrypoints_origination(
        self, client: Client, session
    ):
        path = os.path.join(
            CONTRACT_PATH, 'entrypoints', 'no_entrypoint_target.tz'
        )
        originate(
            client,
            session,
            path,
            'Pair "hello" 42',
            1000,
            contract_name='target_no_entrypoints',
        )

    def test_target_without_default_origination(self, client: Client, session):
        path = os.path.join(
            CONTRACT_PATH, 'entrypoints', 'no_default_target.tz'
        )
        originate(
            client,
            session,
            path,
            'Pair "hello" 42',
            1000,
            contract_name='target_no_default',
        )

    def test_target_with_root_origination(self, client: Client, session):
        path = os.path.join(CONTRACT_PATH, 'entrypoints', 'rooted_target.tz')
        originate(
            client,
            session,
            path,
            'Pair "hello" 42',
            1000,
            contract_name='rooted_target',
        )

    def test_manager_set_delegate(self, client: Client):
        client.set_delegate('manager', 'bootstrap2', [])
        utils.bake(client, 'bootstrap5')
        bootstrap2_pkh = IDENTITIES['bootstrap2']['identity']
        client.set_delegate('delegatable_target', bootstrap2_pkh, [])
        utils.bake(client, 'bootstrap5')
        delegate = IDENTITIES['bootstrap2']['identity']
        assert client.get_delegate('manager', []).delegate == delegate
        assert (
            client.get_delegate('delegatable_target', []).delegate == delegate
        )
        client.set_delegate('manager', 'bootstrap3', [])
        utils.bake(client, 'bootstrap5')
        client.set_delegate('delegatable_target', 'bootstrap3', [])
        utils.bake(client, 'bootstrap5')
        delegate = IDENTITIES['bootstrap3']['identity']
        assert client.get_delegate('manager', []).delegate == delegate
        assert (
            client.get_delegate('delegatable_target', []).delegate == delegate
        )

    def test_manager_withdraw_delegate(self, client: Client):
        client.withdraw_delegate('manager', [])
        utils.bake(client, 'bootstrap5')
        client.withdraw_delegate('delegatable_target', [])
        utils.bake(client, 'bootstrap5')
        assert client.get_delegate('manager', []).delegate is None
        assert client.get_delegate('delegatable_target', []).delegate is None

    def test_transfer_to_manager(self, client: Client):
        balance = client.get_mutez_balance('manager')
        balance_bootstrap = client.get_mutez_balance('bootstrap2')
        amount = 10.001
        amount_mutez = utils.mutez_of_tez(amount)
        client.transfer(
            amount,
            'bootstrap2',
            'manager',
            ['--gas-limit', f'{128 * 15450 + 108}'],
        )
        utils.bake(client, 'bootstrap5')
        new_balance = client.get_mutez_balance('manager')
        new_balance_bootstrap = client.get_mutez_balance('bootstrap2')
        fee = 0.000548
        fee_mutez = utils.mutez_of_tez(fee)
        assert balance + amount_mutez == new_balance
        assert (
            balance_bootstrap - fee_mutez - amount_mutez
            == new_balance_bootstrap
        )

    def test_simple_transfer_from_manager_to_implicit(self, client: Client):
        balance = client.get_mutez_balance('manager')
        balance_bootstrap = client.get_mutez_balance('bootstrap2')
        amount = 10.1
        amount_mutez = utils.mutez_of_tez(amount)
        client.transfer(
            amount,
            'manager',
            'bootstrap2',
            ['--gas-limit', f'{128 * 26350 + 12}'],
        )
        utils.bake(client, 'bootstrap5')
        new_balance = client.get_mutez_balance('manager')
        new_balance_bootstrap = client.get_mutez_balance('bootstrap2')
        fee = 0.000794
        fee_mutez = utils.mutez_of_tez(fee)
        assert balance - amount_mutez == new_balance
        assert (
            balance_bootstrap + amount_mutez - fee_mutez
            == new_balance_bootstrap
        )

    def test_transfer_from_manager_to_manager(self, client: Client):
        balance = client.get_mutez_balance('manager')
        balance_dest = client.get_mutez_balance('manager2')
        balance_bootstrap = client.get_mutez_balance('bootstrap2')
        amount = 10
        amount_mutez = utils.mutez_of_tez(amount)
        client.transfer(
            amount,
            'manager',
            'manager2',
            ['--gas-limit', f'{128 * 44950 + 112}'],
        )
        utils.bake(client, 'bootstrap5')
        new_balance = client.get_mutez_balance('manager')
        new_balance_dest = client.get_mutez_balance('manager2')
        new_balance_bootstrap = client.get_mutez_balance('bootstrap2')
        fee = 0.001124
        fee_mutez = utils.mutez_of_tez(fee)
        assert balance_bootstrap - fee_mutez == new_balance_bootstrap
        assert balance - amount_mutez == new_balance
        assert balance_dest + amount_mutez == new_balance_dest

    def test_transfer_from_manager_to_default(self, client: Client):
        client.transfer(
            10, 'manager', 'bootstrap2', ['--entrypoint', 'default']
        )
        utils.bake(client, 'bootstrap5')
        client.transfer(10, 'manager', 'manager', ['--entrypoint', 'default'])
        utils.bake(client, 'bootstrap5')

    def test_transfer_from_manager_to_target(self, client: Client):
        client.transfer(10, 'manager', 'target', ['--burn-cap', '0.356'])
        utils.bake(client, 'bootstrap5')

    def test_transfer_from_manager_to_entrypoint_with_args(
        self, client: Client
    ):
        arg = 'Pair "hello" 42'
        # using 'transfer'
        client.transfer(
            0,
            'manager',
            'target',
            ['--entrypoint', 'add_left', '--arg', arg, '--burn-cap', '0.067'],
        )
        utils.bake(client, 'bootstrap5')
        client.transfer(
            0,
            'manager',
            'target',
            ['--entrypoint', 'mem_left', '--arg', '"hello"'],
        )
        utils.bake(client, 'bootstrap5')

        # using 'call'
        client.call(
            'manager',
            'target',
            ['--entrypoint', 'add_left', '--arg', arg, '--burn-cap', '0.067'],
        )
        utils.bake(client, 'bootstrap5')
        client.call(
            'manager',
            'target',
            ['--entrypoint', 'mem_left', '--arg', '"hello"'],
        )
        utils.bake(client, 'bootstrap5')

    def test_transfer_from_manager_no_entrypoint_with_args(
        self, client: Client
    ):
        arg = 'Left Unit'
        client.transfer(0, 'manager', 'target_no_entrypoints', ['--arg', arg])
        utils.bake(client, 'bootstrap5')

        client.call('manager', 'target_no_entrypoints', ['--arg', arg])
        utils.bake(client, 'bootstrap5')

    def test_transfer_from_manager_to_no_default_with_args(
        self, client: Client
    ):
        arg = 'Left Unit'
        client.transfer(0, 'manager', 'target_no_default', ['--arg', arg])
        utils.bake(client, 'bootstrap5')

        client.call('manager', 'target_no_default', ['--arg', arg])
        utils.bake(client, 'bootstrap5')

    def test_transfer_from_manager_to_rooted_target_with_args(
        self, client: Client
    ):
        arg = 'Left Unit'
        client.transfer(
            0,
            'manager',
            'rooted_target',
            ['--arg', arg, '--entrypoint', 'root'],
        )
        utils.bake(client, 'bootstrap5')

        client.call(
            'manager', 'rooted_target', ['--arg', arg, '--entrypoint', 'root']
        )
        utils.bake(client, 'bootstrap5')

    def test_transfer_json_to_entrypoint_with_args(self, client):
        balance = client.get_mutez_balance('manager')
        balance_bootstrap = client.get_mutez_balance('bootstrap2')
        fee = 0.0123
        fee_mutez = utils.mutez_of_tez(fee)
        json_obj = [
            {
                "destination": "target",
                "amount": "0",
                "fee": str(fee),
                "gas-limit": "65942",
                "storage-limit": "1024",
                "arg": 'Pair "hello" 42',
                "entrypoint": "add_left",
            }
        ]
        json_ops = json.dumps(json_obj, separators=(',', ':'))
        client.run(client.cmd_batch('manager', json_ops))
        utils.bake(client, 'bootstrap5')
        new_balance = client.get_mutez_balance('manager')
        new_balance_bootstrap = client.get_mutez_balance('bootstrap2')
        assert balance == new_balance
        assert balance_bootstrap - fee_mutez == new_balance_bootstrap

    def test_multiple_transfers(self, client):
        balance = client.get_mutez_balance('manager')
        balance_bootstrap2 = client.get_mutez_balance('bootstrap2')
        balance_bootstrap3 = client.get_mutez_balance('bootstrap3')
        amount_2 = 10.1
        amount_mutez_2 = utils.mutez_of_tez(amount_2)
        amount_3 = 11.01
        amount_mutez_3 = utils.mutez_of_tez(amount_3)
        json_obj = [
            {"destination": "bootstrap2", "amount": str(amount_2)},
            {"destination": "bootstrap3", "amount": str(amount_3)},
        ]
        json_ops = json.dumps(json_obj, separators=(',', ':'))
        client.run(client.cmd_batch('manager', json_ops))
        utils.bake(client, 'bootstrap5')
        new_balance = client.get_mutez_balance('manager')
        new_balance_bootstrap2 = client.get_mutez_balance('bootstrap2')
        new_balance_bootstrap3 = client.get_mutez_balance('bootstrap3')
        fee_mutez = 794 + 698
        assert balance - amount_mutez_2 - amount_mutez_3 == new_balance
        assert (
            balance_bootstrap2 + amount_mutez_2 - fee_mutez
            == new_balance_bootstrap2
        )
        assert balance_bootstrap3 + amount_mutez_3 == new_balance_bootstrap3


# This test to verifies contract execution order. There are 3
# contracts: Storer, Caller, and Appender. Storer appends its argument
# to storage. Caller calls the list of unit contracts in its
# storage. Appender calls the string contract in its storage with a
# stored argument.
#
# For each test, there is one unique Storer. Each test is
# parameterized by a tree and the expected final storage of the
# Storer. A leaf in the tree is a string. Inner nodes are lists of
# leafs/inner nodes. The test maps maps over this tree to build a
# tree of contracts. Leaf nodes map to Appender contracts calling
# the Storer. Inner nodes map to Caller contract that calling
# children.
#
# Example. Given the tree: ["A", ["B"], "C"], we obtain
#  Caller([Appender("A"), Caller([Appender("B")]), Appender("C")])
# Before the protocol 009, contract execution order was in BFS
# In BFS, Storer would've ended up with storage ACB.
# In DFS, Storer will end up with storage ABC.
@pytest.mark.contract
@pytest.mark.incremental
class TestExecutionOrdering:
    STORER = f'{CONTRACT_PATH}/mini_scenarios/execution_order_storer.tz'
    CALLER = f'{CONTRACT_PATH}/mini_scenarios/execution_order_caller.tz'
    APPENDER = f'{CONTRACT_PATH}/mini_scenarios/execution_order_appender.tz'

    def originate_storer(self, client: Client, session: dict):
        origination = originate(
            client, session, self.STORER, '""', 0, arguments=['--force']
        )
        session['storer'] = origination.contract
        utils.bake(client, 'bootstrap3')
        return origination.contract

    def originate_appender(
        self, client: Client, session: dict, storer: str, argument: str
    ):
        origination = originate(
            client,
            session,
            self.APPENDER,
            f'Pair "{storer}" "{argument}"',
            0,
            contract_name=f'appender-{argument}',
            arguments=['--force'],
        )
        session[f'appender.{argument}'] = origination.contract
        utils.bake(client, 'bootstrap3')
        return origination.contract

    def originate_caller(
        self, client: Client, session: dict, callees: List[str]
    ):
        storage = "{" + '; '.join(map('"{}"'.format, callees)) + "}"
        origination = originate(
            client,
            session,
            self.CALLER,
            storage,
            0,
            contract_name=f'caller-{hash(storage)}',
        )
        utils.bake(client, 'bootstrap3')
        return origination.contract

    @pytest.mark.parametrize(
        "tree, expected",
        [
            # before 009, the result should be "DABCEFG".
            ([["A", "B", "C"], "D", ["E", "F", "G"]], "ABCDEFG"),
            # before 009, the result should be "ACB".
            ([["A", ["B"], "C"]], "ABC"),
            # before 009, the result should be "ABDC".
            ([["A", ["B", ["C"], "D"]]], "ABCD"),
            ([], ""),
        ],
    )
    def test_ordering(
        self,
        client: Client,
        session: dict,
        # approximation of recursive type annotation
        tree: Union[str, List[Any]],
        expected: str,
    ):
        storer = self.originate_storer(client, session)

        def deploy_tree(tree: Union[str, List[Any]]) -> str:
            # leaf
            if isinstance(tree, str):
                # deploy and return caller str
                return self.originate_appender(client, session, storer, tree)
            # inner node
            children = list(map(deploy_tree, tree))
            return self.originate_caller(client, session, children)

        root = deploy_tree(tree)

        client.transfer(
            0,
            'bootstrap2',
            root,
            ["--burn-cap", "5"],
        )
        utils.bake(client, 'bootstrap3')
        assert client.get_storage(storer) == '"{}"'.format(expected)


@pytest.mark.slow
@pytest.mark.contract
class TestContracts:
    """Test type checking and execution of a bunch of contracts"""

    @pytest.mark.parametrize("contract", all_contracts())
    def test_typecheck(self, client: Client, contract):
        assert contract.endswith(
            '.tz'
        ), "test contract should have .tz extension"
        client.typecheck(os.path.join(CONTRACT_PATH, contract))

    @pytest.mark.parametrize("contract", all_legacy_contracts())
    def test_deprecated_typecheck_breaks(self, client, contract):
        if contract in [
            "legacy/create_contract.tz",
            "legacy/create_contract_flags.tz",
            "legacy/create_contract_rootname.tz",
        ]:
            with utils.assert_run_failure(r'ill-typed script'):
                client.typecheck(os.path.join(CONTRACT_PATH, contract))
        else:
            with utils.assert_run_failure(r'Use of deprecated instruction'):
                client.typecheck(os.path.join(CONTRACT_PATH, contract))

    @pytest.mark.parametrize("contract", all_legacy_contracts())
    def test_deprecated_typecheck_in_legacy(self, client, contract):
        if contract in [
            "legacy/create_contract.tz",
            "legacy/create_contract_flags.tz",
            "legacy/create_contract_rootname.tz",
        ]:
            with utils.assert_run_failure(r'ill-typed script'):
                client.typecheck(
                    os.path.join(CONTRACT_PATH, contract), legacy=True
                )
        else:
            with utils.assert_run_failure(r'Use of deprecated instruction'):
                client.typecheck(
                    os.path.join(CONTRACT_PATH, contract), legacy=True
                )

    @pytest.mark.parametrize(
        "contract,error_pattern",
        [
            # operations cannot be PACKed
            (
                "pack_operation.tz",
                r'operation type forbidden in parameter, storage and constants',
            ),
            # big_maps cannot be PACKed
            (
                "pack_big_map.tz",
                r'big_map or sapling_state type not expected here',
            ),
            (
                "invalid_self_entrypoint.tz",
                r'Contract has no entrypoint named D',
            ),
            ("contract_annotation_default.tz", r'unexpected annotation'),
            # Missing field
            (
                "missing_only_storage_field.tz",
                r'Missing contract field: storage',
            ),
            ("missing_only_code_field.tz", r'Missing contract field: code'),
            (
                "missing_only_parameter_field.tz",
                r'Missing contract field: parameter',
            ),
            (
                "missing_parameter_and_storage_fields.tz",
                r'Missing contract field: parameter',
            ),
            # Duplicated field
            (
                "multiple_parameter_field.tz",
                r'duplicate contract field: parameter',
            ),
            ("multiple_code_field.tz", r'duplicate contract field: code'),
            ("multiple_storage_field.tz", r'duplicate contract field: storage'),
            # The first duplicated field is reported, storage in this case
            (
                "multiple_storage_and_code_fields.tz",
                r'duplicate contract field: storage',
            ),
            # error message for set update on non-comparable type
            (
                "set_update_non_comparable.tz",
                r'Type nat is not compatible with type list operation',
            ),
            # error message for the arity of the chain_id type
            (
                "chain_id_arity.tz",
                r'primitive chain_id expects 0 arguments but is given 1',
            ),
            # error message for DIP over the limit
            ("big_dip.tz", r'expected a positive 10-bit integer'),
            # error message for DROP over the limit
            ("big_drop.tz", r'expected a positive 10-bit integer'),
            # error message for set update on non-comparable type
            (
                "set_update_non_comparable.tz",
                r'Type nat is not compatible with type list operation',
            ),
            # error message for attempting to push a value of type never
            ("never_literal.tz", r'type never has no inhabitant.'),
            # field annotation mismatch with UNPAIR
            (
                "unpair_field_annotation_mismatch.tz",
                r'The field access annotation does not match',
            ),
            # COMB, UNCOMB, and DUP cannot take 0 as argument
            ("comb0.tz", r"PAIR expects an argument of at least 2"),
            ("comb1.tz", r"PAIR expects an argument of at least 2"),
            ("uncomb0.tz", r"UNPAIR expects an argument of at least 2"),
            ("uncomb1.tz", r"UNPAIR expects an argument of at least 2"),
            ("dup0.tz", r"DUP n expects an argument of at least 1"),
            (
                "push_big_map_with_id_with_parens.tz",
                r"big_map or sapling_state type not expected here",
            ),
            (
                "push_big_map_with_id_without_parens.tz",
                r"primitive PUSH expects 2 arguments but is given 4",
            ),
            # sapling_state is not packable
            (
                "pack_sapling_state.tz",
                r"big_map or sapling_state type not expected here",
            ),
            # sapling_state is not packable
            (
                "unpack_sapling_state.tz",
                r"big_map or sapling_state type not expected here",
            ),
            # Ticket duplication attempt
            ("ticket_dup.tz", r'DUP used on the non-dupable type ticket nat'),
            # error message for ticket unpack
            ("ticket_unpack.tz", r'Ticket in unauthorized position'),
            # error message for attempting to use APPLY to capture a ticket
            ("ticket_apply.tz", r'Ticket in unauthorized position'),
            # error message for attempting to wrap a ticket in a ticket
            (
                "ticket_in_ticket.tz",
                r'comparable type expected.Type ticket unit is not comparable',
            ),
        ],
    )
    def test_ill_typecheck(self, client: Client, contract, error_pattern):
        with utils.assert_run_failure(error_pattern):
            client.typecheck(os.path.join(ILLTYPED_CONTRACT_PATH, contract))

    def test_zero_transfer_to_implicit_contract(self, client):
        pubkey = IDENTITIES['bootstrap3']['identity']
        err = (
            'Transaction of 0ꜩ towards a contract without code are '
            rf'forbidden \({pubkey}\).'
        )
        with utils.assert_run_failure(err):
            client.transfer(0, 'bootstrap2', 'bootstrap3', [])

    def test_zero_transfer_to_nonexistent_contract(self, client):
        nonexistent = "KT1Fcq4inD44aMhmUiTEHR1QMQwJT7p2u641"
        err = rf'Contract {nonexistent} does not exist'
        with utils.assert_run_failure(err):
            client.transfer(0, 'bootstrap2', nonexistent, [])


FIRST_EXPLOSION = '''
{ parameter unit;
  storage unit;
  code{ DROP; PUSH nat 0 ;
        DUP ; PAIR ;
        DUP ; PAIR ;
        DUP ; PAIR ;
        DUP ; PAIR ;
        DUP ; PAIR ;
        DUP ; PAIR ;
        DUP ; PAIR ;
        DUP ; PAIR ;
        DROP ; UNIT ; NIL operation ; PAIR} }
'''


# FIRST_EXPLOSION costs a large amount of gas just for typechecking.
# FIRST_EXPLOSION_BIGTYPE type size exceeds the protocol set bound.
FIRST_EXPLOSION_BIGTYPE = '''
{ parameter unit;
  storage unit;
  code{ DROP; PUSH nat 0 ;
        DUP ; PAIR ;
        DUP ; PAIR ;
        DUP ; PAIR ;
        DUP ; PAIR ;
        DUP ; PAIR ;
        DUP ; PAIR ;
        DUP ; PAIR ;
        DUP ; PAIR ;
        DUP ; PAIR ;
        DUP ; PAIR ;
        DROP ; UNIT ; NIL operation ; PAIR} }
'''


SECOND_EXPLOSION = '''
{ parameter (list int) ;
  storage (list (list (list int))) ;
  code { CAR ; DIP { NIL (list int) } ;
         DUP ; ITER { DROP ; DUP ; DIP { CONS } } ;
         DROP ; DIP { NIL (list (list int)) } ;
         DUP ; ITER { DROP ; DUP ; DIP { CONS } } ;
         DROP ; NIL operation ; PAIR } }
'''


@pytest.mark.contract
class TestGasBound:
    def test_write_contract(self, tmpdir, session: dict):
        items = {
            'first_explosion.tz': FIRST_EXPLOSION,
            'first_explosion_bigtype.tz': FIRST_EXPLOSION_BIGTYPE,
            'second_explosion.tz': SECOND_EXPLOSION,
        }.items()
        for name, script in items:
            contract = f'{tmpdir}/{name}'
            with open(contract, 'w') as contract_file:
                contract_file.write(script)
                session[name] = contract

    def test_originate_first_explosion(self, client: Client, session: dict):
        name = 'first_explosion.tz'
        contract = session[name]
        client.typecheck(contract)
        args = ['-G', f'{1870}', '--burn-cap', '10']

        expected_error = "Gas limit exceeded during typechecking or execution"
        with utils.assert_run_failure(expected_error):
            client.originate(f'{name}', 0, 'bootstrap1', contract, args)

    def test_originate_big_type(self, client: Client, session: dict):
        name = 'first_explosion_bigtype.tz'
        contract = session[name]

        # We could not be bothered with finding how to escape parentheses
        # so we put dots
        expected_error = "type size .1023. exceeded maximum type size .1000."
        with utils.assert_run_failure(expected_error):
            client.typecheck(contract)

    def test_originate_second_explosion(self, client: Client, session: dict):
        name = 'second_explosion.tz'
        contract = session[name]
        storage = '{}'
        inp = '{1;2;3;4;5;6;7;8;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1}'
        client.run_script(contract, storage, inp)

    def test_originate_second_explosion_fail(
        self, client: Client, session: dict
    ):
        name = 'second_explosion.tz'
        contract = session[name]
        storage = '{}'
        inp = (
            '{1;2;3;4;5;6;7;8;9;0;1;2;3;4;5;6;7;1;1;1;1;1;1;1;1;1;1;1'
            + ';1;1;1;1;1;1;1;1;1;1;1;1;1;1}'
        )

        expected_error = (
            "Cannot serialize the resulting storage"
            + " value within the provided gas bounds."
        )
        with utils.assert_run_failure(expected_error):
            client.run_script(contract, storage, inp, gas=9290)

    def test_typecheck_map_dup_key(self, client: Client):

        expected_error = (
            'Map literals cannot contain duplicate'
            + ' keys, however a duplicate key was found'
        )
        with utils.assert_run_failure(expected_error):
            client.typecheck_data('{ Elt 0 1 ; Elt 0 1}', '(map nat nat)')

    def test_typecheck_map_bad_ordering(self, client: Client):

        expected_error = (
            "Keys in a map literal must be in strictly"
            + " ascending order, but they were unordered in literal"
        )
        with utils.assert_run_failure(expected_error):
            client.typecheck_data(
                '{ Elt 0 1 ; Elt 10 1 ; Elt 5 1 }', '(map nat nat)'
            )

    def test_typecheck_set_bad_ordering(self, client: Client):

        expected_error = (
            "Values in a set literal must be in strictly"
            + " ascending order, but they were unordered in literal"
        )
        with utils.assert_run_failure(expected_error):
            client.typecheck_data('{ "A" ; "C" ; "B" }', '(set string)')

    def test_typecheck_set_no_duplicates(self, client: Client):
        expected_error = (
            "Set literals cannot contain duplicate values,"
            + " however a duplicate value was found"
        )
        with utils.assert_run_failure(expected_error):
            client.typecheck_data('{ "A" ; "B" ; "B" }', '(set string)')


@pytest.mark.contract
class TestChainId:
    def test_chain_id_opcode(self, client: Client, session: dict):
        path = os.path.join(CONTRACT_PATH, 'opcodes', 'chain_id.tz')
        originate(client, session, path, 'Unit', 0)
        client.call('bootstrap2', "chain_id", [])
        utils.bake(client, 'bootstrap5')

    def test_chain_id_authentication_origination(self, client: Client, session):
        path = os.path.join(
            CONTRACT_PATH, 'mini_scenarios', 'authentication.tz'
        )
        pubkey = IDENTITIES['bootstrap1']['public']
        originate(client, session, path, f'Pair 0 "{pubkey}"', 1000)
        utils.bake(client, 'bootstrap5')

    def test_chain_id_authentication_first_run(
        self, client: Client, session: dict
    ):
        destination = IDENTITIES['bootstrap2']['identity']
        operation = (
            '{DROP; NIL operation; '
            + f'PUSH address "{destination}"; '
            + 'CONTRACT unit; ASSERT_SOME; PUSH mutez 1000; UNIT; '
            + 'TRANSFER_TOKENS; CONS}'
        )
        chain_id = client.rpc('get', 'chains/main/chain_id')
        contract_address = session['contract']
        packed = client.pack(
            f'Pair (Pair "{chain_id}" "{contract_address}") '
            + f'(Pair {operation} 0)',
            'pair (pair chain_id address)'
            + '(pair (lambda unit (list operation)) nat)',
        )
        signature = client.sign_bytes_of_string(packed, "bootstrap1")
        client.call(
            'bootstrap2',
            'authentication',
            ['--arg', f'Pair {operation} \"{signature}\"'],
        )
        utils.bake(client, 'bootstrap5')


@pytest.mark.contract
class TestBigMapToSelf:
    def test_big_map_to_self_origination(self, client: Client, session: dict):
        path = os.path.join(CONTRACT_PATH, 'opcodes', 'big_map_to_self.tz')
        originate(client, session, path, '{}', 0)
        utils.bake(client, 'bootstrap5')

    def test_big_map_to_self_transfer(self, client: Client):
        client.call('bootstrap2', "big_map_to_self", [])
        utils.bake(client, 'bootstrap5')

        client.transfer(0, 'bootstrap2', "big_map_to_self", [])
        utils.bake(client, 'bootstrap5')


@pytest.mark.contract
class TestNonRegression:
    """Test contract-related non-regressions"""

    def test_issue_242_originate(self, client: Client, session: dict):
        path = os.path.join(CONTRACT_PATH, 'non_regression', 'bug_262.tz')
        originate(client, session, path, 'Unit', 1)

    def test_issue_242_assert_balance(self, client: Client):
        assert client.get_balance('bug_262') == 1


@pytest.mark.contract
class TestMiniScenarios:
    """Test mini scenarios"""

    # replay.tz related tests
    def test_replay_originate(self, client: Client, session: dict):
        path = os.path.join(CONTRACT_PATH, 'mini_scenarios', 'replay.tz')
        originate(client, session, path, 'Unit', 0)

    def test_replay_transfer_fail(self, client: Client):
        with utils.assert_run_failure("Internal operation replay attempt"):
            client.transfer(10, "bootstrap1", "replay", [])

    # create_contract.tz related tests
    def test_create_contract_originate(self, client: Client, session: dict):
        path = os.path.join(
            CONTRACT_PATH, 'mini_scenarios', 'create_contract.tz'
        )
        originate(client, session, path, 'Unit', 1000)

    def test_create_contract_balance(self, client: Client):
        assert client.get_balance('create_contract') == 1000

    def test_create_contract_perform_creation(self, client: Client):
        transfer_result = client.transfer(
            0,
            "bootstrap1",
            "create_contract",
            ['-arg', 'None', '--burn-cap', '10'],
        )
        utils.bake(client, 'bootstrap5')
        pattern = r"New contract (\w*) originated"
        match = re.search(pattern, transfer_result.client_output)
        assert match is not None
        kt_1 = match.groups()[0]
        assert client.get_storage(kt_1) == '"abcdefg"'
        assert client.get_balance(kt_1) == 100
        assert client.get_balance('create_contract') == 900

    # Originates a contract that when called, creates a contract with a
    # rootname annotation. Such annotations comes in two flavors, thus the
    # parameterization. Then calls the first contract and verifies the
    # existence and type of the root entrypoint of the create contract.
    @pytest.mark.parametrize(
        "contract",
        [
            'create_contract_rootname.tz',
            'create_contract_rootname_alt.tz',
        ],
    )
    def test_create_contract_rootname_originate(
        self, client: Client, session: dict, contract
    ):
        path = os.path.join(CONTRACT_PATH, 'opcodes', contract)
        origination_res = originate(client, session, path, 'None', 1000)

        transfer_result = client.transfer(
            0,
            "bootstrap1",
            origination_res.contract,
            ['-arg', 'Unit', '--burn-cap', '10'],
        )
        utils.bake(client, 'bootstrap5')

        pattern = r"New contract (\w*) originated"
        match = re.search(pattern, transfer_result.client_output)
        assert match is not None
        kt_1 = match.groups()[0]

        entrypoint_type = client.get_contract_entrypoint_type(
            'root', kt_1
        ).entrypoint_type

        assert entrypoint_type == 'unit', (
            'the entrypoint my_root of the originated contract should exist'
            'with type unit'
        )

    # default_account.tz related tests
    def test_default_account_originate(self, client: Client, session: dict):
        path = os.path.join(
            CONTRACT_PATH, 'mini_scenarios', 'default_account.tz'
        )
        originate(client, session, path, 'Unit', 1000)

    def test_default_account_transfer_then_bake(self, client: Client):
        tz1 = IDENTITIES['bootstrap4']['identity']
        client.transfer(
            0,
            "bootstrap1",
            "default_account",
            ['-arg', f'"{tz1}"', '--burn-cap', '10'],
        )
        utils.bake(client, 'bootstrap5')
        account = 'tz1SuakBpFdG9b4twyfrSMqZzruxhpMeSrE5'
        client.transfer(
            0,
            "bootstrap1",
            "default_account",
            ['-arg', f'"{account}"', '--burn-cap', '10'],
        )
        utils.bake(client, 'bootstrap5')
        assert client.get_balance(account) == 100

    # Test bytes, SHA252, CHECK_SIGNATURE
    def test_reveal_signed_preimage_originate(
        self, client: Client, session: dict
    ):
        path = os.path.join(
            CONTRACT_PATH, 'mini_scenarios', 'reveal_signed_preimage.tz'
        )
        byt = (
            '0x9995c2ef7bcc7ae3bd15bdd9b02'
            + 'dc6e877c27b26732340d641a4cbc6524813bb'
        )
        sign = 'p2pk66uq221795tFxT7jfNmXtBMdjMf6RAaxRTwv1dbuSHbH6yfqGwz'
        storage = f'(Pair {byt} "{sign}")'
        originate(client, session, path, storage, 1000)

    def test_wrong_preimage(self, client: Client):
        byt = (
            '0x050100000027566f756c657a2d766f75732'
            + '0636f75636865722061766563206d6f692c20636520736f6972'
        )
        sign = (
            'p2sigvgDSBnN1bUsfwyMvqpJA1cFhE5s5oi7SetJ'
            + 'VQ6LJsbFrU2idPvnvwJhf5v9DhM9ZTX1euS9DgWozVw6BTHiK9VcQVpAU8'
        )
        arg = f'(Pair {byt} "{sign}")'

        # We check failure of ASSERT_CMPEQ in the script.
        with utils.assert_run_failure("At line 8 characters 9 to 21"):
            client.transfer(
                0,
                "bootstrap1",
                "reveal_signed_preimage",
                ['-arg', arg, '--burn-cap', '10'],
            )

    def test_wrong_signature(self, client: Client):
        byt = (
            '0x050100000027566f756c657a2d766f757320636'
            + 'f75636865722061766563206d6f692c20636520736f6972203f'
        )
        sign = (
            'p2sigvgDSBnN1bUsfwyMvqpJA1cFhE5s5oi7SetJVQ6'
            + 'LJsbFrU2idPvnvwJhf5v9DhM9ZTX1euS9DgWozVw6BTHiK9VcQVpAU8'
        )
        arg = f'(Pair {byt} "{sign}")'

        # We check failure of CHECK_SIGNATURE ; ASSERT in the script.
        with utils.assert_run_failure("At line 15 characters 9 to 15"):
            client.transfer(
                0,
                "bootstrap1",
                "reveal_signed_preimage",
                ['-arg', arg, '--burn-cap', '10'],
            )

    def test_good_preimage_and_signature(self, client: Client):
        byt = (
            '0x050100000027566f756c657a2d766f757320636f7563'
            + '6865722061766563206d6f692c20636520736f6972203f'
        )
        sign = (
            'p2sigsceCzcDw2AeYDzUonj4JT341WC9Px4wdhHBxbZcG1F'
            + 'hfqFVuG7f2fGCzrEHSAZgrsrQWpxduDPk9qZRgrpzwJnSHC3gZJ'
        )
        arg = f'(Pair {byt} "{sign}")'
        client.transfer(
            0,
            "bootstrap1",
            "reveal_signed_preimage",
            ['-arg', arg, '--burn-cap', '10'],
        )
        utils.bake(client, 'bootstrap5')

    # Test vote_for_delegate
    def test_vote_for_delegate_originate(self, client: Client, session: dict):
        b_3 = IDENTITIES['bootstrap3']['identity']
        b_4 = IDENTITIES['bootstrap4']['identity']
        path = os.path.join(
            CONTRACT_PATH, 'mini_scenarios', 'vote_for_delegate.tz'
        )
        storage = f'''(Pair (Pair "{b_3}" None) (Pair "{b_4}" None))'''
        originate(client, session, path, storage, 1000)
        assert client.get_delegate('vote_for_delegate').delegate is None

    def test_vote_for_delegate_wrong_identity1(self, client: Client):
        # We check failure of CHECK_SIGNATURE ; ASSERT in the script.
        with utils.assert_run_failure("At line 15 characters 57 to 61"):
            client.transfer(
                0,
                "bootstrap1",
                "vote_for_delegate",
                ['-arg', 'None', '--burn-cap', '10'],
            )

    def test_vote_for_delegate_wrong_identity2(self, client: Client):
        # We check failure of CHECK_SIGNATURE ; ASSERT in the script.
        with utils.assert_run_failure("At line 15 characters 57 to 61"):
            client.transfer(
                0,
                "bootstrap2",
                "vote_for_delegate",
                ['-arg', 'None', '--burn-cap', '10'],
            )

    def test_vote_for_delegate_b3_vote_for_b5(self, client: Client):
        b_5 = IDENTITIES['bootstrap5']['identity']
        client.transfer(
            0,
            "bootstrap3",
            "vote_for_delegate",
            ['-arg', f'(Some "{b_5}")', '--burn-cap', '10'],
        )
        utils.bake(client, 'bootstrap5')
        storage = client.get_storage('vote_for_delegate')
        assert re.search(b_5, storage)

    def test_vote_for_delegate_still_no_delegate1(self, client: Client):
        assert client.get_delegate('vote_for_delegate').delegate is None

    def test_vote_for_delegate_b4_vote_for_b2(self, client: Client):
        b_2 = IDENTITIES['bootstrap2']['identity']
        client.transfer(
            0,
            "bootstrap4",
            "vote_for_delegate",
            ['-arg', f'(Some "{b_2}")', '--burn-cap', '10'],
        )
        utils.bake(client, 'bootstrap5')
        storage = client.get_storage('vote_for_delegate')
        assert re.search(b_2, storage)

    def test_vote_for_delegate_still_no_delegate2(self, client: Client):
        assert client.get_delegate('vote_for_delegate').delegate is None

    def test_vote_for_delegate_b4_vote_for_b5(self, client: Client):
        b_5 = IDENTITIES['bootstrap5']['identity']
        client.transfer(
            0,
            "bootstrap4",
            "vote_for_delegate",
            ['-arg', f'(Some "{b_5}")', '--burn-cap', '10'],
        )
        utils.bake(client, 'bootstrap5')
        storage = client.get_storage('vote_for_delegate')
        assert re.search(b_5, storage)

    def test_vote_for_delegate_has_delegate(self, client: Client):
        b_5 = IDENTITIES['bootstrap5']['identity']
        result = client.get_delegate('vote_for_delegate')
        assert result.delegate == b_5

    def test_multiple_entrypoints_counter(self, session: dict, client: Client):
        path = os.path.join(
            CONTRACT_PATH, 'mini_scenarios', 'multiple_entrypoints_counter.tz'
        )

        storage = 'None'

        # originate contract
        originate(client, session, path, storage, 0)
        utils.bake(client, 'bootstrap5')

        # call contract: creates the internal contract and calls it.
        client.transfer(
            0,
            'bootstrap1',
            'multiple_entrypoints_counter',
            ['--burn-cap', '10'],
        )
        utils.bake(client, 'bootstrap5')
        assert client.get_storage('multiple_entrypoints_counter') == 'None', (
            "The storage of the multiple_entrypoints_counter contract"
            " should be None"
        )

    # Test CONTRACT with/without entrypoint annotation on literal address
    # parameters with/without entrypoint annotation
    def test_originate_simple_entrypoints(self, session: dict, client: Client):
        """originates the contract simple_entrypoints.tz
         with entrypoint %A of type unit used in
        test_simple_entrypoints"""

        contract_target = os.path.join(
            CONTRACT_PATH, 'entrypoints', 'simple_entrypoints.tz'
        )
        originate(client, session, contract_target, 'Unit', 0)
        utils.bake(client, 'bootstrap5')

    @pytest.mark.parametrize(
        'contract_annotation, contract_type, param, expected_storage',
        [
            # tests passing adr to CONTRACT %A unit
            # where adr has an entrypoint %A of type unit, is allowed.
            ('%A', 'unit', '"{adr}"', '(Some "{adr}%A")'),
            ('%B', 'string', '"{adr}"', '(Some "{adr}%B")'),
            ('%C', 'nat', '"{adr}"', '(Some "{adr}%C")'),
            # tests passing adr%A to CONTRACT %A unit: redundant specification
            # of entrypoint not allowed so CONTRACT returns None
            ('%A', 'unit', '"{adr}%A"', 'None'),
            ('%A', 'unit', '"{adr}%B"', 'None'),
            ('%A', 'unit', '"{adr}%D"', 'None'),
            ('%A', 'unit', '"{adr}%A"', 'None'),
            ('%B', 'unit', '"{adr}%A"', 'None'),
            ('%D', 'unit', '"{adr}%A"', 'None'),
            # tests passing adr%A to CONTRACT unit:
            # where adr has an entrypoint %A of type unit, is allowed.
            ('', 'unit', '"{adr}%A"', '(Some "{adr}%A")'),
            ('', 'string', '"{adr}%B"', '(Some "{adr}%B")'),
            ('', 'nat', '"{adr}%C"', '(Some "{adr}%C")'),
            # tests passing adr%B to CONTRACT unit:
            # as entrypoint %B of simple_entrypoints.tz has type string,
            # CONTRACT will return None.
            ('', 'unit', '"{adr}%B"', 'None'),
            # tests passing adr%D to CONTRACT unit:
            # as entrypoint %D does not exist in simple_entrypoints.tz,
            # CONTRACT will return None.
            ('', 'unit', '"{adr}%D"', 'None'),
            # tests passing adr to CONTRACT unit:
            # as adr does not have type unit, CONTRACT returns None.
            ('', 'unit', '"{adr}"', 'None'),
            # entrypoint that does not exist
            ('%D', 'unit', '"{adr}"', 'None'),
            # ill-typed entrypoints
            ('%A', 'int', '"{adr}"', 'None'),
            ('%B', 'unit', '"{adr}"', 'None'),
            ('%C', 'int', '"{adr}"', 'None'),
        ],
    )
    def test_simple_entrypoints(
        self,
        session,
        client,
        contract_annotation,
        contract_type,
        param,
        expected_storage,
    ):
        contract = f'''parameter address;
storage (option address);
code {{
       CAR;
       CONTRACT {contract_annotation} {contract_type};
       IF_SOME {{ ADDRESS; SOME }} {{ NONE address; }};
       NIL operation;
       PAIR
     }};'''

        param = param.format(adr=session['contract'])
        expected_storage = expected_storage.format(adr=session['contract'])
        run_script_res = client.run_script(contract, 'None', param, file=False)
        assert run_script_res.storage == expected_storage


@pytest.mark.contract
class TestComparables:
    def test_comparable_unit(self, client):
        client.typecheck_data('{}', '(set unit)')
        client.typecheck_data('{Unit}', '(set unit)')

    def test_comparable_options(self, client):
        client.typecheck_data('{}', '(set (option nat))')
        client.typecheck_data('{None; Some 1; Some 2}', '(set (option int))')
        utils.assert_typecheck_data_failure(
            client, '{Some "foo"; Some "bar"}', '(set (option string))'
        )
        utils.assert_typecheck_data_failure(
            client, '{Some Unit; None}', '(set (option unit))'
        )

    def test_comparable_unions(self, client):
        client.typecheck_data('{}', '(set (or unit bool))')
        client.typecheck_data(
            '{Left 3; Left 4; Right "bar"; Right "foo"}',
            '(set (or nat string))',
        )
        utils.assert_typecheck_data_failure(
            client, '{Left 2; Left 1}', '(set (or mutez unit))'
        )
        utils.assert_typecheck_data_failure(
            client, '{Right True; Right False}', '(set (or unit bool))'
        )
        utils.assert_typecheck_data_failure(
            client, '{Right 0; Left 1}', '(set (or nat nat))'
        )

    def test_comparable_pair(self, client: Client):
        # tests that comb pairs are comparable and that the order is the
        # expected one
        client.typecheck_data('{}', '(set (pair nat string))')
        client.typecheck_data('{Pair 0 "foo"}', '(set (pair nat string))')
        client.typecheck_data(
            '{Pair 0 "foo"; Pair 1 "bar"}', '(set (pair nat string))'
        )
        client.typecheck_data(
            '{Pair 0 "bar"; Pair 0 "foo"; \
                                Pair 1 "bar"; Pair 1 "foo"}',
            '(set (pair nat string))',
        )
        client.typecheck_data('{}', '(set (pair nat (pair string bytes)))')

        client.typecheck_data('{}', '(map (pair nat string) unit)')
        client.typecheck_data(
            '{Elt (Pair 0 "foo") Unit}', '(map (pair nat string) unit)'
        )
        client.typecheck_data(
            '{Elt (Pair 0 "foo") Unit; \
                                Elt (Pair 1 "bar") Unit}',
            '(map (pair nat string) unit)',
        )
        client.typecheck_data(
            '{Elt (Pair 0 "bar") Unit; \
                                Elt (Pair 0 "foo") Unit; \
                                Elt (Pair 1 "bar") Unit; \
                                Elt (Pair 1 "foo") Unit}',
            '(map (pair nat string) unit)',
        )
        client.typecheck_data('{}', '(map (pair nat (pair string bytes)) unit)')

        client.typecheck_data('{}', '(big_map (pair nat string) unit)')
        client.typecheck_data(
            '{Elt (Pair 0 "foo") Unit}', '(big_map (pair nat string) unit)'
        )
        client.typecheck_data(
            '{Elt (Pair 0 "foo") Unit; \
                                Elt (Pair 1 "bar") Unit}',
            '(big_map (pair nat string) unit)',
        )
        client.typecheck_data(
            '{Elt (Pair 0 "bar") Unit; \
                                Elt (Pair 0 "foo") Unit; \
                                Elt (Pair 1 "bar") Unit; \
                                Elt (Pair 1 "foo") Unit}',
            '(big_map (pair nat string) unit)',
        )
        client.typecheck_data(
            '{}', '(big_map (pair nat (pair string bytes)) unit)'
        )
        client.typecheck_data('{}', '(set (pair (pair nat nat) nat))')
        client.typecheck_data(
            '{}',
            '(set (pair (pair int nat) \
                                                (pair bool bytes)))',
        )

    def test_order_of_pairs(self, client: Client):
        # tests that badly-ordered set literals are rejected
        utils.assert_typecheck_data_failure(
            client, '{Pair 0 "foo"; Pair 0 "bar"}', '(set (pair nat string))'
        )
        utils.assert_typecheck_data_failure(
            client, '{Pair 1 "bar"; Pair 0 "foo"}', '(set (pair nat string))'
        )

    def test_comparable_chain_id(self, client):
        client.typecheck_data('{}', '(set chain_id)')
        chain1 = client.rpc('get', 'chains/main/chain_id')
        chain2 = 'NetXZVhNXbDTx5M'
        utils.assert_typecheck_data_failure(
            client,
            '{"' + f'{chain1}' + '"; "' + f'{chain2}' + '"}',
            '(set chain_id)',
        )
        client.typecheck_data(
            '{"' + f'{chain2}' + '"; "' + f'{chain1}' + '"}', '(set chain_id)'
        )

    def test_comparable_signature(self, client):
        client.typecheck_data('{}', '(set signature)')
        packed = client.pack('Unit', 'unit')
        sig1 = client.sign_bytes_of_string(packed, "bootstrap1")
        sig2 = client.sign_bytes_of_string(packed, "bootstrap2")
        utils.assert_typecheck_data_failure(
            client,
            '{"' + f'{sig1}' + '"; "' + f'{sig2}' + '"}',
            '(set signature)',
        )
        client.typecheck_data(
            '{"' + f'{sig2}' + '"; "' + f'{sig1}' + '"}', '(set signature)'
        )

    def test_comparable_key(self, client):
        pubkey1 = IDENTITIES['bootstrap1']['public']
        pubkey2 = IDENTITIES['bootstrap2']['public']
        client.typecheck_data('{}', '(set key)')
        utils.assert_typecheck_data_failure(
            client,
            '{"' + f'{pubkey1}' + '"; "' + f'{pubkey2}' + '"}',
            '(set key)',
        )
        client.typecheck_data(
            '{"' + f'{pubkey2}' + '"; "' + f'{pubkey1}' + '"}', '(set key)'
        )

    def test_comparable_key_different_schemes(self, client):
        client.gen_key('sk1', ['--sig', 'ed25519'])
        key1 = client.show_address('sk1').public_key

        client.gen_key('sk2', ['--sig', 'secp256k1'])
        key2 = client.show_address('sk2').public_key

        client.gen_key('sk3', ['--sig', 'p256'])
        key3 = client.show_address('sk3').public_key

        # Three public keys of the three different signature schemes, ordered
        client.typecheck_data(
            '{"' + key1 + '"; "' + key2 + '"; "' + key3 + '"}', '(set key)'
        )

        # Test all orderings that do not respect the comparable order
        utils.assert_typecheck_data_failure(
            client,
            '{"' + key1 + '"; "' + key3 + '"; "' + key2 + '"}',
            '(set key)',
        )

        utils.assert_typecheck_data_failure(
            client,
            '{"' + key2 + '"; "' + key1 + '"; "' + key3 + '"}',
            '(set key)',
        )

        utils.assert_typecheck_data_failure(
            client,
            '{"' + key2 + '"; "' + key3 + '"; "' + key1 + '"}',
            '(set key)',
        )

        utils.assert_typecheck_data_failure(
            client,
            '{"' + key3 + '"; "' + key1 + '"; "' + key2 + '"}',
            '(set key)',
        )

        utils.assert_typecheck_data_failure(
            client,
            '{"' + key3 + '"; "' + key2 + '"; "' + key1 + '"}',
            '(set key)',
        )


@pytest.mark.contract
class TestTypecheckingErrors:
    def test_big_map_arity_error(self, client: Client):
        error_pattern = (
            'primitive EMPTY_BIG_MAP expects 2 arguments but is given 1.'
        )
        with utils.assert_run_failure(error_pattern):
            client.typecheck(
                os.path.join(CONTRACT_PATH, 'ill_typed', 'big_map_arity.tz')
            )


BAD_ANNOT_TEST = '''
parameter bytes;
storage (option (lambda unit unit));
code { CAR; UNPACK (lambda unit unit); NIL operation; PAIR}
'''


@pytest.mark.contract
class TestBadAnnotation:
    def test_write_contract_bad_annot(self, tmpdir, session: dict):
        name = 'bad_annot.tz'
        contract = f'{tmpdir}/{name}'
        script = BAD_ANNOT_TEST
        with open(contract, 'w') as contract_file:
            contract_file.write(script)
            session[name] = contract

    def test_bad_annotation(self, client: Client, session: dict):
        name = 'bad_annot.tz'
        contract = session[name]

        # This was produced by running "tezos-client hash data '{ UNIT
        # ; PAIR ; CAR %faa }' of type 'lambda unit unit'" and
        # replacing the two last bytes (that correspond to the two
        # 'a's at the end of the annotation) by the 0xff byte which is
        # not a valid UTF8-encoding of a string
        parameter = '0x05020000000e034f03420416000000042566ffff'

        res = client.run_script(contract, 'None', parameter)
        assert res.storage == 'None'


@pytest.mark.contract
class TestOrderInTopLevelDoesNotMatter:
    @pytest.fixture
    def contract_splitted_in_top_level_elements(self):
        return [
            "parameter nat",
            "storage unit",
            "code { CDR; NIL operation; PAIR }",
        ]

    def test_shuffle(
        self, client: Client, contract_splitted_in_top_level_elements
    ):
        """
        Test that the storage, code, and parameter sections can appear in any
        order in a contract script.
        """
        for shuffled_list in itertools.permutations(
            contract_splitted_in_top_level_elements
        ):
            contract = ";\n".join(shuffled_list)
            client.typecheck(contract, file=False)


@pytest.mark.contract
@pytest.mark.regression
class TestSelfAddressTransfer:
    def test_self_address_originate_sender(
        self, client_regtest_scrubbed, session
    ):
        client = client_regtest_scrubbed
        path = os.path.join(
            CONTRACT_PATH, 'mini_scenarios', 'self_address_sender.tz'
        )
        originate(client, session, path, 'Unit', 0)

    def test_self_address_originate_receiver(
        self, client_regtest_scrubbed, session
    ):
        client = client_regtest_scrubbed
        path = os.path.join(
            CONTRACT_PATH, 'mini_scenarios', 'self_address_receiver.tz'
        )
        originate(client, session, path, 'Unit', 0)
        session['receiver_address'] = session['contract']

    def test_send_self_address(self, client_regtest_scrubbed, session):
        client = client_regtest_scrubbed
        receiver_address = session['receiver_address']
        client.transfer(
            0,
            'bootstrap2',
            'self_address_sender',
            ['--arg', f'"{receiver_address}"', '--burn-cap', '2'],
        )
        utils.bake(client, 'bootstrap5')


@pytest.mark.slow
@pytest.mark.contract
@pytest.mark.regression
class TestScriptHashRegression:
    @pytest.mark.parametrize("contract", all_contracts())
    def test_contract_hash(self, client_regtest: Client, contract):
        client = client_regtest
        assert contract.endswith(
            '.tz'
        ), "test contract should have .tz extension"
        client.hash_script(os.path.join(CONTRACT_PATH, contract))


@pytest.mark.contract
class TestScriptHashOrigination:
    def test_contract_hash_with_origination(
        self, client: Client, session: dict
    ):
        script = 'parameter unit; storage unit; code {CAR; NIL operation; PAIR}'
        originate(
            client,
            session,
            contract=script,
            init_storage='Unit',
            amount=1000,
            contract_name='dummy_contract',
        )
        hash1 = client.hash_script(script)
        hash2 = client.get_script_hash('dummy_contract')
        assert hash1 == hash2


@pytest.mark.contract
@pytest.mark.regression
class TestNormalize:
    """Regression tests for the "normalize data" command."""

    modes = [None, 'Readable', 'Optimized', 'Optimized_legacy']

    @pytest.mark.parametrize('mode', modes)
    def test_normalize_unparsing_mode(self, client_regtest_scrubbed, mode):
        client = client_regtest_scrubbed
        input_data = (
            '{Pair 0 3 6 9; Pair 1 (Pair 4 (Pair 7 10)); {2; 5; 8; 11}}'
        )
        input_type = 'list (pair nat nat nat nat)'
        client.normalize(input_data, input_type, mode=mode)

    def test_normalize_legacy_flag(self, client_regtest_scrubbed):
        client = client_regtest_scrubbed
        input_data = '{Elt %a 0 1}'
        input_type = 'map nat nat'
        client.normalize(input_data, input_type, legacy=True)
        error_pattern = 'unexpected annotation.'
        with utils.assert_run_failure(error_pattern):
            client.normalize(input_data, input_type, legacy=False)

    @pytest.mark.parametrize('mode', modes)
    def test_normalize_script(self, client_regtest_scrubbed, mode):
        client = client_regtest_scrubbed
        path = os.path.join(CONTRACT_PATH, 'opcodes', 'comb-literals.tz')
        client.normalize_script(path, mode=mode)

    types = [
        'nat',
        'list nat',
        'pair nat int',
        'list (pair nat int)',
        'pair nat int bool',
        'list (pair nat int bool)',
        'pair nat int bool bytes',
        'list (pair nat int bool bytes)',
    ]

    @pytest.mark.parametrize('typ', types)
    def test_normalize_type(self, client_regtest_scrubbed, typ):
        client = client_regtest_scrubbed
        client.normalize_type(typ)


@pytest.mark.contract
class TestTZIP4View:
    """Tests for the "run tzip4 view" command."""

    def test_run_view(self, client: Client, session: dict):

        path = os.path.join(CONTRACT_PATH, 'mini_scenarios', 'tzip4_view.tz')
        originate(
            client,
            session,
            contract=path,
            init_storage='Unit',
            amount=1000,
            contract_name='view_contract',
        )
        client.bake('bootstrap5')

        const_view_res = client.run_view(
            "view_const", "view_contract", "Unit", []
        )
        add_view_res = client.run_view(
            "view_add", "view_contract", "Pair 1 3", []
        )

        assert const_view_res.result == "5\n" and add_view_res.result == "4\n"
