import os
import subprocess
import pytest
from tools import utils, paths, constants

CONTRACT_PATH = f'{paths.TEZOS_HOME}/src/bin_client/test/contracts'

BAKE_ARGS = ['--minimal-timestamp']


def file_basename(path):
    return os.path.splitext(os.path.basename(path))[0]


def originate(client,
              session,
              contract,
              init_storage,
              amount,
              contract_name=None,
              sender='bootstrap1',
              baker='bootstrap5'):
    if contract_name is None:
        contract_name = file_basename(contract)
    args = ['--init', init_storage, '--burn-cap', '10.0']
    origination = client.originate(contract_name, amount,
                                   sender, contract, args)
    session['contract'] = origination.contract
    print(origination.contract)
    client.bake(baker, BAKE_ARGS)
    assert utils.check_block_contains_operations(client,
                                                 [origination.operation_hash])


def all_contracts():
    directories = ['attic', 'opcodes']
    contracts = []
    for directory in directories:
        for contract in os.listdir(f'{CONTRACT_PATH}/{directory}'):
            contracts.append(f'{directory}/{contract}')
    return contracts


@pytest.mark.slow
@pytest.mark.contract
class TestContracts:
    """Test type checking and execution of a bunch of contracts"""

    def test_gen_keys(self, client):
        client.gen_key('foo')
        client.gen_key('bar')

    @pytest.mark.parametrize("contract", all_contracts())
    def test_typecheck(self, client, contract):
        if contract.endswith('.tz'):
            client.typecheck(f'{CONTRACT_PATH}/{contract}')

    # TODO add more tests here
    @pytest.mark.parametrize("contract,param,storage,expected",
                             [('opcodes/ret_int.tz', 'None', 'Unit',
                               '(Some 300)')])
    def test_run(self, client, contract, param, storage, expected):
        if contract.endswith('.tz'):
            contract = f'{CONTRACT_PATH}/{contract}'
            run_script_res = client.run_script(contract, param, storage)
            assert run_script_res.storage == expected


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
        DUP ; PAIR } }
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

    def test_write_contract(self, tmpdir, session):
        items = {'first_explosion.tz': FIRST_EXPLOSION,
                 'second_explosion.tz': SECOND_EXPLOSION}.items()
        for name, script in items:
            contract = f'{tmpdir}/{name}'
            with open(contract, 'w') as contract_file:
                contract_file.write(script)
                session[name] = contract

    def test_originate_first_explosion(self, client, session):
        name = 'first_explosion.tz'
        contract = session[name]
        # TODO client.typecheck(contract) -> type error not what we expect?
        args = ['-G', '8000', '--burn-cap', '10']
        with pytest.raises(subprocess.CalledProcessError) as _exc:
            client.originate(f'{name}', 0, 'bootstrap1', contract, args)
        # TODO capture output and check error message is correct

    def test_originate_second_explosion(self, client, session):
        name = 'second_explosion.tz'
        contract = session[name]
        storage = '{}'
        inp = '{1;2;3;4;5;6;7;8;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1}'
        client.run_script(contract, storage, inp)

    # TODO complete with tests from test_contract.sh


@pytest.mark.contract
class TestChainId:

    def test_chain_id_opcode(self, client, session):
        path = f'{CONTRACT_PATH}/opcodes/chain_id.tz'
        originate(client, session, path, 'Unit', 0)
        client.transfer(0, 'bootstrap2', "chain_id", [])
        client.bake('bootstrap5', BAKE_ARGS)

    def test_chain_id_authentication_origination(self, client, session):
        path = f'{CONTRACT_PATH}/mini_scenarios/authentication.tz'
        pubkey = constants.IDENTITIES['bootstrap1']['public']
        originate(client, session, path, f'Pair 0 "{pubkey}"', 1000)
        client.bake('bootstrap5', BAKE_ARGS)

    def test_chain_id_authentication_first_run(self, client, session):
        destination = constants.IDENTITIES['bootstrap2']['identity']
        operation = '{DROP; NIL operation; ' + \
            f'PUSH address "{destination}"; ' + \
            'CONTRACT unit; ASSERT_SOME; PUSH mutez 1000; UNIT; ' + \
            'TRANSFER_TOKENS; CONS}'
        chain_id = client.rpc('get', 'chains/main/chain_id')
        contract_address = session['contract']
        packed = client.pack(
            f'Pair (Pair "{chain_id}" "{contract_address}") ' +
            f'(Pair {operation} 0)',
            'pair (pair chain_id address)' +
            '(pair (lambda unit (list operation)) nat)')
        signature = client.sign(packed, "bootstrap1")
        client.transfer(0, 'bootstrap2', 'authentication',
                        ['--arg', f'Pair {operation} \"{signature}\"'])
        client.bake('bootstrap5', BAKE_ARGS)
