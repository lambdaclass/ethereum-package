"""
ethlambda launcher.

Translates the Lean pipeline's per-node record into the ethlambda CLI surface
(see lambdaclass/ethlambda's `bin/ethlambda/src/main.rs` and the matching
lean-quickstart `client-cmds/ethlambda-cmd.sh`).

Lifecycle (called by ../lean_launcher.star):
  1. `initialize()` - add a Kurtosis service mounting both the P2P keys
     artifact and the hash-sig (XMSS) keys artifact (neither depends on the
     node IP). The container runs `tail -f` on a log file so Kurtosis keeps
     the service alive while the genesis pipeline computes things downstream
     that DO need the IP.
  2. `start()` - after the genesis tool has produced the text artifacts
     (config.yaml, annotated_validators.yaml, nodes.yaml, validator-config.yaml),
     stage each text file inside the running container via `plan.exec`
     (Kurtosis doesn't let us mount new file artifacts onto a running
     service), then launch the ethlambda binary as a backgrounded `nohup`
     process. We use `plan.exec` for both steps rather than a second
     `add_service`, because the Starlark validator rejects two
     `add_service` calls with the same name even when `force_update=True`.

The hash-sig keys, P2P keys, and a stable directory layout under
`/network-configs/` are established by `initialize`; `start` only adds the
files whose contents depend on the live IP allocation.
"""

constants = import_module("../../package_io/constants.star")
lean_shared = import_module("../lean_shared.star")
lean_context = import_module("../lean_context.star")

ENTRYPOINT = "/usr/local/bin/ethlambda"
GENESIS_MOUNT = constants.LEAN_GENESIS_MOUNTPOINT_ON_CLIENTS
HASH_SIG_MOUNT = GENESIS_MOUNT + "/hash-sig-keys"
DATA_DIR = "/data"
NODE_KEY_MOUNT = constants.LEAN_NODE_KEY_MOUNTPOINT_ON_CLIENTS

GENESIS_TEXT_FILES = [
    "config.yaml",
    "annotated_validators.yaml",
    "nodes.yaml",
    "validator-config.yaml",
]


def initialize(plan, node, p2p_keys_artifact, hash_sig_artifact):
    """Phase 1: stand the placeholder service up so Kurtosis assigns an IP.

    Both the P2P keys and the XMSS keys are mounted here because neither
    depends on the IP allocation. Genesis text files (config.yaml,
    nodes.yaml, etc.) are staged later via `plan.exec` once the genesis
    tool has computed them against the live IPs.
    """
    cfg_kwargs = lean_shared.common_cfg_kwargs(node)
    cfg_kwargs.update(
        {
            "image": node["image"],
            # Override the image ENTRYPOINT so the container doesn't try to
            # start ethlambda with no flags before we've written the genesis
            # files in.
            "entrypoint": ["/bin/sh", "-c"],
            "cmd": lean_shared.lean_tail_logs_cmd(node["service_name"])[2:],
            "files": {
                NODE_KEY_MOUNT: p2p_keys_artifact,
                HASH_SIG_MOUNT: hash_sig_artifact,
            },
        }
    )
    return plan.add_service(node["service_name"], ServiceConfig(**cfg_kwargs))


def start(
    plan,
    node,
    service,
    genesis_artifact,
    hash_sig_artifact,
    el_context=None,
    jwt_file=None,
    el_genesis_block_hash=None,
):
    """Phase 3: stage genesis text files into the running container and
    launch the ethlambda binary as a backgrounded process.

    `hash_sig_artifact` is unused here because it was already mounted in
    `initialize()` — we keep the parameter for shape parity with the other
    Lean clients.

    When `el_context`, `jwt_file`, and `el_genesis_block_hash` are all set,
    ethlambda is launched with Engine API pairing
    (`--execution-endpoint`, `--execution-jwt-secret`,
    `--execution-genesis-block-hash`). Otherwise it boots Lean-only.
    See lambdaclass/ethlambda#367 for the Engine API plumbing.
    """
    service_name = service.name
    log_file = lean_shared.lean_log_file_path(service_name)

    # Stage each text genesis file inside the running container. We read
    # the artifact's contents via plan.run_sh (the output is a Kurtosis
    # runtime future) and then plan.exec a `cat > path` heredoc that
    # carries the future as a string argument — Kurtosis resolves the
    # future at apply time so the literal file contents land in the
    # target. mkdir is idempotent.
    plan.exec(
        service_name=service_name,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "mkdir -p {0}".format(GENESIS_MOUNT)],
        ),
        description="Preparing genesis mount on {0}".format(service_name),
    )
    for filename in GENESIS_TEXT_FILES:
        read = plan.run_sh(
            run="cat /src/{0}".format(filename),
            files={"/src": genesis_artifact},
            description="Reading {0} for {1}".format(filename, service_name),
        )
        plan.exec(
            service_name=service_name,
            recipe=ExecRecipe(
                command=[
                    "/bin/sh",
                    "-c",
                    "cat > {0}/{1} <<'ETHLAMBDA_EOF'\n{2}\nETHLAMBDA_EOF".format(
                        GENESIS_MOUNT,
                        filename,
                        read.output,
                    ),
                ],
            ),
            description="Staging {0} into {1}".format(filename, service_name),
        )

    # Build and start the ethlambda command. The placeholder `tail -f`
    # keeps the container alive, so we run ethlambda as a nohup
    # background process and let its stdout/stderr flow into the same
    # log file the tail is already watching.
    cmd_parts = [
        ENTRYPOINT,
        "--genesis",
        "{0}/config.yaml".format(GENESIS_MOUNT),
        "--validators",
        "{0}/annotated_validators.yaml".format(GENESIS_MOUNT),
        "--bootnodes",
        "{0}/nodes.yaml".format(GENESIS_MOUNT),
        "--validator-config",
        "{0}/validator-config.yaml".format(GENESIS_MOUNT),
        "--hash-sig-keys-dir",
        HASH_SIG_MOUNT,
        "--data-dir",
        DATA_DIR,
        "--gossipsub-port",
        str(constants.LEAN_QUIC_PORT_NUM),
        "--node-id",
        node["node_name"],
        "--node-key",
        "{0}/{1}.key".format(NODE_KEY_MOUNT, node["node_name"]),
        "--http-address",
        "0.0.0.0",
        "--api-port",
        str(constants.LEAN_API_PORT_NUM),
        "--metrics-port",
        str(constants.LEAN_METRICS_PORT_NUM),
    ]
    if node["is_aggregator"]:
        cmd_parts.append("--is-aggregator")

    # Engine API pairing: present only when this node was synthesized from
    # a `participants:` entry with a paired EL (lean_launcher fills the
    # three values in tandem). We stage the JWT secret into the running
    # container via plan.exec (same trick as the genesis files) since
    # Kurtosis doesn't let us add a new files mount to an already-running
    # service.
    if el_context != None and jwt_file != None and el_genesis_block_hash != None:
        jwt_path = "{0}/jwtsecret".format(GENESIS_MOUNT)
        jwt_read = plan.run_sh(
            run="cat /src/jwtsecret",
            files={"/src": jwt_file},
            description="Reading JWT secret for {0}".format(node["service_name"]),
        )
        plan.exec(
            service_name=node["service_name"],
            recipe=ExecRecipe(
                command=[
                    "/bin/sh",
                    "-c",
                    "cat > {0} <<'ETHLAMBDA_JWT_EOF'\n{1}\nETHLAMBDA_JWT_EOF".format(
                        jwt_path,
                        jwt_read.output,
                    ),
                ],
            ),
            description="Staging JWT into {0}".format(node["service_name"]),
        )
        engine_endpoint = "http://{0}:{1}".format(
            el_context.ip_addr, el_context.engine_rpc_port_num
        )
        cmd_parts.extend(
            [
                "--execution-endpoint",
                engine_endpoint,
                "--execution-jwt-secret",
                jwt_path,
                "--execution-genesis-block-hash",
                el_genesis_block_hash,
            ]
        )

    for extra in node["extra_params"]:
        cmd_parts.append(extra)

    rust_log = ""
    if node["log_level"] != "":
        rust_log = "RUST_LOG='{0}' ".format(node["log_level"])

    nohup_cmd = "setsid -f sh -c \"exec {0}{1}\" < /dev/null >> {2} 2>&1".format(
        rust_log,
        " ".join(cmd_parts),
        log_file,
    )
    plan.exec(
        service_name=service_name,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", nohup_cmd],
        ),
        description="Starting ethlambda binary on {0}".format(service_name),
    )

    api_url = "http://{0}:{1}".format(
        service.ip_address,
        constants.LEAN_API_PORT_NUM,
    )
    metrics_url = "http://{0}:{1}/metrics".format(
        service.ip_address,
        constants.LEAN_METRICS_PORT_NUM,
    )

    return lean_context.new_lean_context(
        client_name=constants.LEAN_TYPE.ethlambda,
        service_name=service_name,
        ip_address=service.ip_address,
        quic_port=constants.LEAN_QUIC_PORT_NUM,
        api_port=constants.LEAN_API_PORT_NUM,
        metrics_port=constants.LEAN_METRICS_PORT_NUM,
        api_url=api_url,
        metrics_url=metrics_url,
        metrics_info={
            "name": service_name,
            "url": metrics_url,
            "path": "/metrics",
            "config": node["prometheus_config"],
        },
    )
