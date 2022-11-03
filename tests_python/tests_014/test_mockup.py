""" This file tests the mockup mode (octez-client --mode mockup).
    In this mode the client does not need a node running.

    Make sure to either use the fixture mockup_client or
    to mimick it if you want a mockup with custom parameters.

    Care is taken not to leave any base_dir dangling after
    tests are finished. Please continue doing this.
"""
import json
import os
import tempfile
from typing import Any, Optional, Tuple
import pytest
from launchers.sandbox import Sandbox
from client.client import Client
from client.client_output import CreateMockupResult

from . import protocol

_BA_FLAG = "bootstrap-accounts"
_PC_FLAG = "protocol-constants"


def _create_accounts_list():
    """
    Returns a list of dictionary with 3 entries, that are
    valid for being translated to json and passed
    to `--bootstrap-accounts`
    """
    accounts_list = []

    def add_account(name: str, sk_uri: str, amount: str):
        entry = {
            "name": name,
            "sk_uri": "unencrypted:" + sk_uri,
            "amount": amount,
        }
        accounts_list.append(entry)

    # Took json structure from
    # https://gitlab.com/tezos/tezos/-/merge_requests/1720
    add_account(
        "bootstrap0",
        "edsk2uqQB9AY4FvioK2YMdfmyMrer5R8mGFyuaLLFfSRo8EoyNdht3",
        "2000000000000",
    )
    add_account(
        "bootstrap1",
        "edsk3gUfUPyBSfrS9CCgmCiQsTCHGkviBDusMxDJstFtojtc1zcpsh",
        "1000000000000",
    )

    return accounts_list


def _try_json_loads(flag: str, string: str) -> Any:
    """Converts the given string to a json object"""
    try:
        return json.loads(string)
    except json.JSONDecodeError:
        pytest.fail(
            f"""Write back of {flag} value is not valid json:
{string}"""
        )
        # Added to get rid of pylint warning inconsistent-return-statements.
        # pytest.fail has no return value (NoReturn).
        return None


def _get_state_using_config_init_mockup(
    mock_client: Client,
) -> Tuple[str, str]:
    """
    Calls `config init mockup` on a mockup client and returns
    the strings of the bootstrap accounts and the protocol
    constants

    Note that because this a mockup specific operation, the `mock_client`
    parameter must be in mockup mode; do not give a vanilla client.
    """
    ba_json_file = tempfile.mktemp(prefix='tezos-bootstrap-accounts')
    pc_json_file = tempfile.mktemp(prefix='tezos-proto-consts')

    mock_client.run(
        [
            "--protocol",
            protocol.HASH,
            "config",
            "init",
            f"--{_BA_FLAG}",
            ba_json_file,
            f"--{_PC_FLAG}",
            pc_json_file,
        ]
    )

    with open(ba_json_file) as handle:
        ba_str = handle.read()
    with open(pc_json_file) as handle:
        pc_str = handle.read()

    # Cleanup of tempfile.mktemp
    os.remove(ba_json_file)
    os.remove(pc_json_file)

    return (ba_str, pc_str)


def _get_state_using_config_show_mockup(
    mock_client: Client,
) -> Tuple[str, str]:
    """
    Calls `--mode mockup config show` on a mockup client and returns
    the strings of the bootstrap accounts and the protocol
    constants, by parsing standard output.

    Note that because this a mockup specific operation, the `mock_client`
    parameter must be in mockup mode; do not give a vanilla client.
    """

    def _find_line_starting_with(strings, searched) -> int:
        i = 0
        for string in strings:
            if string.startswith(searched):
                return i
            i += 1
        return -1

    def _parse_config_init_output(string: str) -> Tuple[str, str]:
        """Parses the output of `--mode mockup config init`
        and return the json of the bootstrap accounts
        and the protocol constants
        """
        tagline1 = f"Default value of --{_BA_FLAG}:"
        bootstrap_accounts_index = string.find(tagline1)
        assert bootstrap_accounts_index >= 0, f"{_BA_FLAG} line not found"

        tagline2 = f"Default value of --{_PC_FLAG}:"
        proto_constants_index = string.find(tagline2)
        assert proto_constants_index > 0, f"{_PC_FLAG} line not found"

        bc_json = string[
            bootstrap_accounts_index + len(tagline1) : proto_constants_index - 1
        ]

        pc_json = string[proto_constants_index + len(tagline2) + 1 :]
        return (bc_json, pc_json)

    stdout = mock_client.run(["--protocol", protocol.HASH, "config", "show"])
    return _parse_config_init_output(stdout)


def write_file(filename, contents):
    filename.write(contents)
    filename.flush()


def _gen_assert_msg(flag, sent, received):
    return (
        f"Json sent with --{flag} differs from json received"
        f"\nJson sent is:\n{sent}"
        f"\nwhile json received is:\n{received}"
    )


def rm_amounts(bootstrap_accounts):
    for account in bootstrap_accounts:
        account.pop('amount', None)


def compute_expected_amounts(
    bootstrap_accounts, frozen_deposits_percentage: int
) -> None:
    pct = 100 - frozen_deposits_percentage
    for account in bootstrap_accounts:
        account['amount'] = str(int(pct * int(account['amount']) / 100))


def _test_create_mockup_init_show_roundtrip(
    sandbox: Sandbox,
    read_initial_state,
    read_final_state,
    bootstrap_json: Optional[str] = None,
    protocol_constants_json: Optional[str] = None,
):
    """1/ Creates a mockup, using possibly custom bootstrap_accounts
       (as specified by `bootstrap_json`)
    2/ Then execute either `--mode mockup config show` or
       `--mode mockup config init` to obtain the mockup's parameters
       (parse stdout if `show` is called,
       read the files generated by `init` otherwise)

       This is done by executing `read_initial_state`
    3/ Recreate a mockup using the output gathered in 2/ and call
       `--mode mockup config show`/`--mode mockup config init`
       (this is done by executing `read_final_state`) to check that output
       received is similar to output seen in 2.

    This is a roundtrip test.
    """

    ba_file = None
    pc_file = None

    try:
        if protocol_constants_json is not None:
            pc_file = tempfile.mktemp(prefix='tezos-proto-consts')
            with open(pc_file, 'w') as handle:
                handle.write(protocol_constants_json)

        if bootstrap_json is not None:
            ba_file = tempfile.mktemp(prefix='tezos-bootstrap-accounts')
            with open(ba_file, 'w') as handle:
                handle.write(bootstrap_json)

        with tempfile.TemporaryDirectory(prefix='octez-client.') as base_dir:
            # Follow pattern of mockup_client fixture:
            unmanaged_client = sandbox.create_client(base_dir=base_dir)
            res = unmanaged_client.create_mockup(
                protocol=protocol.HASH,
                bootstrap_accounts_file=ba_file,
                protocol_constants_file=pc_file,
            ).create_mockup_result
            assert res == CreateMockupResult.OK
            mock_client = sandbox.create_client(
                base_dir=base_dir, mode="mockup"
            )
            (ba_str, pc_str) = read_initial_state(mock_client)
    finally:
        if pc_file is not None:
            os.remove(pc_file)
        if ba_file is not None:
            os.remove(ba_file)

    # 2a/ Check the json obtained is valid by building json objects
    ba_sent = _try_json_loads(_BA_FLAG, ba_str)
    pc_sent = _try_json_loads(_PC_FLAG, pc_str)

    # Test that the initial mockup call honored the values it received. If
    # it didn't, all calls would return the default values all along, and
    # everything would seem fine; but it wouldn't be. This was witnessed in
    # https://gitlab.com/tezos/tezos/-/issues/938
    if bootstrap_json:
        ba_input = json.loads(bootstrap_json)
        # adjust amount field on Tenderbake w.r.t. to frozen_deposits_percentage
        compute_expected_amounts(
            ba_input, int(pc_sent['frozen_deposits_percentage'])
        )
        assert ba_sent == ba_input

    if protocol_constants_json:
        pc_input = json.loads(protocol_constants_json)
        assert pc_sent == pc_input

    # 3/ Pass obtained json to a new mockup instance, to check json
    # is valid w.r.t. ocaml encoding

    # Use another directory so that the constants change takes effect
    with tempfile.TemporaryDirectory(
        prefix='octez-client.'
    ) as base_dir, tempfile.NamedTemporaryFile(
        prefix='tezos-bootstrap-accounts', mode='w+t'
    ) as ba_json_file, tempfile.NamedTemporaryFile(
        prefix='tezos-proto-consts', mode='w+t'
    ) as pc_json_file, tempfile.TemporaryDirectory(
        prefix='octez-client.'
    ) as base_dir:

        write_file(ba_json_file, ba_str)
        write_file(pc_json_file, pc_str)

        with tempfile.TemporaryDirectory(prefix='octez-client.') as base_dir:
            # Follow pattern of mockup_client fixture:
            unmanaged_client = sandbox.create_client(base_dir=base_dir)
            res = unmanaged_client.create_mockup(
                protocol=protocol.HASH,
                protocol_constants_file=pc_json_file.name,
                bootstrap_accounts_file=ba_json_file.name,
            ).create_mockup_result
            assert res == CreateMockupResult.OK
            mock_client = sandbox.create_client(
                base_dir=base_dir, mode="mockup"
            )
            # 4/ Retrieve state again
            (ba_received_str, pc_received_str) = read_final_state(mock_client)

    # Convert it to json objects (check that json is valid)
    ba_received = _try_json_loads(_BA_FLAG, ba_received_str)
    pc_received = _try_json_loads(_PC_FLAG, pc_received_str)

    # and finally check that json objects received are the same
    # as the ones that were given as input

    # adjust amount field on Tenderbake w.r.t. to frozen_deposits_percentage
    compute_expected_amounts(
        ba_sent, int(pc_sent['frozen_deposits_percentage'])
    )

    assert ba_sent == ba_received, _gen_assert_msg(
        _BA_FLAG, ba_sent, ba_received
    )
    assert pc_sent == pc_received, _gen_assert_msg(
        _PC_FLAG, pc_sent, pc_received
    )


@pytest.mark.client
@pytest.mark.parametrize(
    'initial_bootstrap_accounts', [None, json.dumps(_create_accounts_list())]
)
# The following values should be different from the default ones in
# order to check loading of the parameters.
@pytest.mark.parametrize(
    'protocol_constants',
    [
        None,
        json.dumps(
            {
                "initial_timestamp": "2021-02-03T12:34:56Z",
                "chain_id": "NetXaFDF7xZQCpR",
                "min_proposal_quorum": 501,
                "quorum_max": 7001,
                "quorum_min": 2001,
                "hard_storage_limit_per_operation": "60001",
                "cost_per_byte": "251",
                "baking_reward_fixed_portion": "20000000",
                "baking_reward_bonus_per_slot": "2500",
                "endorsing_reward_per_slot": "2857",
                "origination_size": 258,
                "vdf_difficulty": "1000000000",
                "seed_nonce_revelation_tip": "125001",
                "testnet_dictator": None,
                "tokens_per_roll": "8000000001",
                "proof_of_work_threshold": "-2",
                "hard_gas_limit_per_block": "10400001",
                "hard_gas_limit_per_operation": "1040001",
                'consensus_committee_size': 12,
                # DO NOT EDIT the value consensus_threshold this is actually a
                # constant, not a parameter
                'consensus_threshold': 0,
                'initial_seed': None,
                'minimal_participation_ratio': {
                    'denominator': 5,
                    'numerator': 1,
                },
                'minimal_block_delay': '1',
                'delay_increment_per_round': '1',
                'max_slashing_period': 12,
                "cycles_per_voting_period": 7,
                "blocks_per_stake_snapshot": 5,
                "blocks_per_commitment": 5,
                "nonce_revelation_threshold": 5,
                "blocks_per_cycle": 9,
                "preserved_cycles": 3,
                "liquidity_baking_toggle_ema_threshold": 1000000000,
                "liquidity_baking_subsidy": "2500000",
                "liquidity_baking_sunset_level": 1024,
                "max_operations_time_to_live": 120,
                "frozen_deposits_percentage": 10,
                'ratio_of_frozen_deposits_slashed_per_double_endorsement': {
                    'numerator': 1,
                    'denominator': 2,
                },
                "double_baking_punishment": "640000001",
                "cache_script_size": 100000001,
                "cache_stake_distribution_cycles": 10,
                "cache_sampler_state_cycles": 10,
                "tx_rollup_enable": False,
                "tx_rollup_origination_size": 30_000,
                "tx_rollup_hard_size_limit_per_inbox": 100_000,
                "tx_rollup_hard_size_limit_per_message": 5_000,
                "tx_rollup_commitment_bond": "10000000000",
                "tx_rollup_finality_period": 2000,
                "tx_rollup_withdraw_period": 123456,
                "tx_rollup_max_inboxes_count": 2218,
                "tx_rollup_max_messages_per_inbox": 1010,
                'tx_rollup_max_withdrawals_per_batch': 255,
                "tx_rollup_max_commitments_count": 666,
                "tx_rollup_cost_per_byte_ema_factor": 321,
                "tx_rollup_max_ticket_payload_size": 10_240,
                "tx_rollup_rejection_max_proof_size": 30_000,
                "tx_rollup_sunset_level": 3_473_409,
                "dal_parametric": {
                    "feature_enable": True,
                    "number_of_slots": 64,
                    "number_of_shards": 1024,
                    "endorsement_lag": 1,
                    "availability_threshold": 25,
                },
                "sc_rollup_enable": False,
                "sc_rollup_origination_size": 6_314,
                "sc_rollup_challenge_window_in_blocks": 20_160,
                "sc_rollup_max_available_messages": 1_000_000,
                "sc_rollup_stake_amount": "42000000",
                "sc_rollup_commitment_period_in_blocks": 40,
                "sc_rollup_max_lookahead_in_blocks": 30_000,
                "sc_rollup_max_active_outbox_levels": 20_160,
                "sc_rollup_max_outbox_messages_per_level": 100,
            }
        ),
    ],
)
@pytest.mark.parametrize(
    'read_initial_state',
    [_get_state_using_config_show_mockup, _get_state_using_config_init_mockup],
)
@pytest.mark.parametrize(
    'read_final_state',
    [_get_state_using_config_show_mockup, _get_state_using_config_init_mockup],
)
def test_create_mockup_config_show_init_roundtrip(
    sandbox: Sandbox,
    initial_bootstrap_accounts,
    protocol_constants,
    read_initial_state,
    read_final_state,
):
    """1/ Create a mockup, using possibly custom bootstrap_accounts
       (as specified by `initial_bootstrap_json`).
    2/ Then execute either `--mode mockup config show`
       or `--mode mockup config init` to obtain the mockup's parameters,
       as specified by `read_initial_state`.
    3/ Recreate a mockup using the output gathered in 2/ and call
       `read_final_state` to check that output
       received is similar to output seen in 2.
    This is a roundtrip test using a matrix.
    """
    _test_create_mockup_init_show_roundtrip(
        sandbox,
        read_initial_state,
        read_final_state,
        initial_bootstrap_accounts,
        protocol_constants,
    )
