import json
import os
import shutil
import subprocess
import sys
import tempfile
from typing import Dict, List, Optional, Tuple

from process import process_utils

# Timeout before killing a node which doesn't react to SIGTERM
TERM_TIMEOUT = 10


def _run_and_print(cmd):
    cmd_str = process_utils.format_command(cmd)
    print(cmd_str)
    completed_process = subprocess.run(
        cmd, capture_output=True, text=True, check=False
    )
    stdout = completed_process.stdout
    stderr = completed_process.stderr
    if stdout:
        print(stdout)
    if stderr:
        print(stderr, file=sys.stderr)
    completed_process.check_returncode()


class Node:
    """Wrapper for the octez-node command.

    This class manages the persistent state of a octez-node
    (the node directory) and provides an API which wraps the node commands.

    Most commands are intended to be used synchronously, for instance:
    - octez-node identity generate
    - octez-node upgrade storage

    octez-node run is intended to be used asynchronously and forks a
    subprocess.

    Typical use.

    node = Node(node_bin,
                p2p_port=p2p_node,
                rpc_port=rpc_node,
                peers=peers_rpc,
                log_file=log_file,
                params=params,
                log_levels=log_levels)

    node.snapshot_import(snapshot) # optional, use a snapshot
    node.init_id() # generate node id
    node.init_config() # generate config file based on parameters
    node.run() # run octez-node process
    node.terminate() # terminate process
    node.run() # re-run using same process
    node.terminate() # or node.kill()
    node.cleanup() # cleanup temp files
    """

    def __init__(
        self,
        node: str,
        config: dict = None,
        expected_pow: float = 0.0,
        node_dir: str = None,
        use_tls: Tuple[str, str] = None,
        params: List[str] = None,
        log_file: str = None,
        p2p_port: int = 9732,
        rpc_port: int = 8732,
        peers: List[int] = None,
        log_levels: Dict[str, str] = None,
        singleprocess: bool = False,
        env: Dict[str, str] = None,
    ):
        """Creates a new Popen instance for a octez-node, and manages context.

        args:
            use_tls (tuple): None if no tls, else couple of strings
                            (certificate, key)

        Creates a temporary node directory unless provided  by caller.
        Generate node identity.
        """
        assert os.path.isfile(node), f'{node} not a file'
        assert node_dir is None or os.path.isdir(node_dir), (
            f'{node_dir} not ' f'a dir'
        )
        if config is None or 'network' not in config:
            if params is None:
                params = ['--network', 'sandbox']
            elif '--network' not in params:
                params = params + ['--network', 'sandbox']

        # the given config will be applied in :func:`init_config`
        self.config = config
        self.log_file = log_file
        self._temp_dir = node_dir is None
        if node_dir is None:
            node_dir = tempfile.mkdtemp(prefix='octez-node.')
        self.node_dir = node_dir
        self.p2p_port = p2p_port
        self.rpc_port = rpc_port
        self.expected_pow = expected_pow
        self.node = node
        self._params = params
        self._run_called_before = False
        singleprocess_opt = ['--singleprocess'] if singleprocess else []
        node_run = [
            node,
            'run',
            '--data-dir',
            node_dir,
            '--no-bootstrap-peers',
        ] + singleprocess_opt
        if params:
            node_run.extend(params)

        if peers is not None:
            for peer in peers:
                node_run.append('--peer')
                node_run.append(f'127.0.0.1:{peer}')

        self.use_tls = use_tls

        new_env = None
        if env is not None:
            new_env = os.environ.copy()
            new_env.update(env)
        if log_levels is not None:
            new_env = os.environ.copy() if new_env is None else new_env
            lwt_log = ";".join(
                f'{key} -> {values}' for key, values in log_levels.items()
            )
            new_env['TEZOS_LOG'] = lwt_log
        self._new_env = new_env
        self._node_run = node_run
        self._process = None  # type: Optional[subprocess.Popen]

    def run(self):
        node_run_str = process_utils.format_command(self._node_run)
        print(node_run_str)
        # overwrite old log on on first invocation only
        overwrite_log = not self._run_called_before
        stdout, stderr = process_utils.prepare_log(
            self._node_run, self.log_file, overwrite_log
        )
        self._process = subprocess.Popen(
            self._node_run, stdout=stdout, stderr=stderr, env=self._new_env
        )
        self._run_called_before = True

    def init_config(self):
        node_config = [
            self.node,
            'config',
            'init',
            '--data-dir',
            self.node_dir,
            '--net-addr',
            f'127.0.0.1:{self.p2p_port}',
            '--rpc-addr',
            f'127.0.0.1:{self.rpc_port}',
            '--expected-pow',
            str(self.expected_pow),
        ]
        if self._params:
            node_config += self._params

        if self.use_tls:
            # We can't create tezos.crt/tezos.key here
            # as node_dir has to be empty when we run node_config
            node_config += [
                '--rpc-tls',
                (f'{self.node_dir}/tezos.crt,' f'{self.node_dir}/tezos.key'),
            ]

        _run_and_print(node_config)

        if self.config is not None:
            config_file = os.path.join(self.node_dir, 'config.json')
            # update the config file with the given config
            with open(config_file, 'r+') as file:
                config = dict(json.loads(file.read()))
                config.update(self.config)
                # overwrite the contents
                file.seek(0)
                file.write(json.dumps(config))
                file.truncate()

    def init_id(self):
        node_identity = [
            self.node,
            'identity',
            'generate',
            str(self.expected_pow),
            '--data-dir',
            self.node_dir,
        ]
        _run_and_print(node_identity)
        if self.use_tls:
            with open(f'{self.node_dir}/tezos.crt', 'w+') as file:
                file.write(self.use_tls[0])
            with open(f'{self.node_dir}/tezos.key', 'w+') as file:
                file.write(self.use_tls[1])

    def upgrade_storage(self):
        node_upgrade = [
            self.node,
            'upgrade',
            'storage',
            '--data-dir',
            self.node_dir,
        ]
        _run_and_print(node_upgrade)

    def snapshot_export(self, file, params=None):
        if params is None:
            params = []
        params = ['--data-dir', self.node_dir] + params
        snapshot_cmd = [self.node, 'snapshot', 'export'] + list(params) + [file]
        _run_and_print(snapshot_cmd)

    def snapshot_import(self, file, params=None):
        if params is None:
            params = []
        params = ['--data-dir', self.node_dir] + params
        snapshot_cmd = [self.node, 'snapshot', 'import'] + list(params) + [file]
        _run_and_print(snapshot_cmd)

    def reconstruct(self, params=None):
        if params is None:
            params = []
        params = ['--data-dir', self.node_dir] + params
        reconstruct_cmd = [self.node, 'reconstruct'] + list(params)
        _run_and_print(reconstruct_cmd)

    def cleanup(self):
        """Remove node directory (only if generated by constructor)"""
        if self._temp_dir:
            shutil.rmtree(self.node_dir)

    def terminate(self) -> None:
        """Send SIGTERM to node, do nothing if node hasn't been run yet"""
        if self._process is not None:
            self._process.terminate()

    def kill(self) -> None:
        """Send SIGKILL to node, do nothing if node hasn't been run yet"""
        if self._process is not None:
            self._process.kill()

    def terminate_or_kill(self) -> None:
        """Try to terminate node gently (SIGTERM) and kill it (SIGKILL)

        if the node is still running after TERM_TIMEOUT. Do nothing
        if node hasn't been run yet.
        """
        if self._process is None:
            return
        self._process.terminate()
        try:
            self._process.wait(timeout=TERM_TIMEOUT)
        except subprocess.TimeoutExpired:
            self._process.kill()

    def poll(self):
        assert self._process
        return self._process.poll()
