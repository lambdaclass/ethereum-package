"""
ream launcher.

Mirrors the ethlambda launcher shape (placeholder service -> genesis pipeline
-> re-issue with full mounts) but translates to ream's CLI surface as
documented in `client-cmds/ream-cmd.sh` in blockblaz/lean-quickstart:

    ream --data-dir <dir> lean_node \
         --network <config.yaml> \
         --validator-registry-path <annotated_validators.yaml> \
         --bootnodes <nodes.yaml> \
         --node-id <name> --node-key <key> \
         --socket-port <quic> \
         --metrics --metrics-address 0.0.0.0 --metrics-port <m> \
         --http-address 0.0.0.0 --http-port <api>

NOTE: ream's `lean_node` subcommand doesn't (yet) consume a hash-sig-keys
directory in its public CLI - it derives its validator set from
`annotated_validators.yaml` + GENESIS_VALIDATORS in config.yaml. The genesis
artifact we mount carries both, so ream needs no extra plumbing.
"""

constants = import_module("../../package_io/constants.star")
lean_shared = import_module("../lean_shared.star")
lean_context = import_module("../lean_context.star")

ENTRYPOINT = "/usr/local/bin/ream"
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
    cfg_kwargs = lean_shared.common_cfg_kwargs(node)
    cfg_kwargs.update(
        {
            "image": node["image"],
            "entrypoint": ["/bin/sh", "-c"],
            "cmd": lean_shared.lean_tail_logs_cmd(node["service_name"])[2:],
            "files": {
                NODE_KEY_MOUNT: p2p_keys_artifact,
                HASH_SIG_MOUNT: hash_sig_artifact,
            },
        }
    )
    return plan.add_service(node["service_name"], ServiceConfig(**cfg_kwargs))


def start(plan, node, service, genesis_artifact, hash_sig_artifact):
    service_name = service.name
    log_file = lean_shared.lean_log_file_path(service_name)

    # Stage the genesis text files into the running container — Kurtosis
    # doesn't allow remounting a new file artifact on an existing service,
    # so we read each file via plan.run_sh (yielding a runtime future) and
    # plan.exec a heredoc that resolves the future at apply time.
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
                    "cat > {0}/{1} <<'REAM_EOF'\n{2}\nREAM_EOF".format(
                        GENESIS_MOUNT, filename, read.output,
                    ),
                ],
            ),
            description="Staging {0} into {1}".format(filename, service_name),
        )

    cmd_parts = [
        ENTRYPOINT,
        "--data-dir", DATA_DIR,
        "lean_node",
        "--network", "{0}/config.yaml".format(GENESIS_MOUNT),
        "--validator-registry-path",
        "{0}/annotated_validators.yaml".format(GENESIS_MOUNT),
        "--bootnodes", "{0}/nodes.yaml".format(GENESIS_MOUNT),
        "--node-id", node["node_name"],
        "--node-key", "{0}/{1}.key".format(NODE_KEY_MOUNT, node["node_name"]),
        "--socket-port", str(constants.LEAN_QUIC_PORT_NUM),
        "--metrics",
        "--metrics-address", "0.0.0.0",
        "--metrics-port", str(constants.LEAN_METRICS_PORT_NUM),
        "--http-address", "0.0.0.0",
        "--http-port", str(constants.LEAN_API_PORT_NUM),
    ]
    if node["is_aggregator"]:
        cmd_parts.append("--is-aggregator")
    for extra in node["extra_params"]:
        cmd_parts.append(extra)

    rust_log = ""
    if node["log_level"] != "":
        rust_log = "RUST_LOG='{0}' ".format(node["log_level"])

    nohup_cmd = "nohup {0}{1} >> {2} 2>&1 &".format(
        rust_log,
        " ".join(cmd_parts),
        log_file,
    )
    plan.exec(
        service_name=service_name,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", nohup_cmd],
        ),
        description="Starting ream binary on {0}".format(service_name),
    )

    api_url = "http://{0}:{1}".format(
        service.ip_address, constants.LEAN_API_PORT_NUM
    )
    metrics_url = "http://{0}:{1}/metrics".format(
        service.ip_address,
        constants.LEAN_METRICS_PORT_NUM,
    )

    return lean_context.new_lean_context(
        client_name=constants.LEAN_TYPE.ream,
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
