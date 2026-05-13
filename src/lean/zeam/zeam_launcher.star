"""
zeam launcher.

Translates the Lean pipeline's per-node record into zeam's CLI surface from
`client-cmds/zeam-cmd.sh` in blockblaz/lean-quickstart.

`blockblaz/zeam:devnet4` is a `scratch`-based image — only the zeam binary
exists at `/app/zig-out/bin/zeam`, no `/bin/sh`, `tail`, `nohup`, or
anything else. The Lean pipeline's placeholder-then-plan.exec pattern
needs a shell to (a) keep the placeholder alive while genesis runs, and
(b) cat-stage text genesis files in. To unblock this without rebuilding
zeam's image, we inject a static busybox binary as a file artifact and
mount it at `/bin/busybox`, then drive everything through it.
"""

constants = import_module("../../package_io/constants.star")
lean_shared = import_module("../lean_shared.star")
lean_context = import_module("../lean_context.star")

ENTRYPOINT = "/app/zig-out/bin/zeam"
GENESIS_MOUNT = constants.LEAN_GENESIS_MOUNTPOINT_ON_CLIENTS
HASH_SIG_MOUNT = GENESIS_MOUNT + "/hash-sig-keys"
DATA_DIR = "/data"
NODE_KEY_MOUNT = constants.LEAN_NODE_KEY_MOUNTPOINT_ON_CLIENTS
BUSYBOX_MOUNT = "/usr/local/bin"
BUSYBOX = "/usr/local/bin/busybox"

GENESIS_TEXT_FILES = [
    "config.yaml",
    "annotated_validators.yaml",
    "nodes.yaml",
    "validator-config.yaml",
    # zeam scans the custom-genesis dir for validators.yaml (PK's raw
    # validator-index assignments); the heredoc-stage covers it since it's
    # plain YAML, no binary content.
    "validators.yaml",
]


def _busybox_artifact(plan):
    # Extract the static busybox binary out of busybox:musl. Once exported
    # as a Kurtosis files artifact it can be mounted into any scratch
    # container as `/usr/local/bin/busybox` so we have a working shell to
    # run plan.exec scripts against.
    return plan.run_sh(
        run="mkdir -p /out && cp /bin/busybox /out/busybox",
        image="busybox:musl",
        store=[StoreSpec(src="/out", name="lean-busybox")],
        description="Extracting static busybox for zeam scratch image",
    ).files_artifacts[0]


def initialize(plan, node, p2p_keys_artifact, hash_sig_artifact):
    busybox_artifact = _busybox_artifact(plan)
    cfg_kwargs = lean_shared.common_cfg_kwargs(node)
    cfg_kwargs.update(
        {
            "image": node["image"],
            # Override the zeam entrypoint with busybox sh; the real zeam
            # binary is invoked later via plan.exec.
            "entrypoint": [BUSYBOX, "sh", "-c"],
            "cmd": [
                # zeam's scratch image has no /usr/bin/touch, /bin/tail, and
                # not even /var/log. Every applet has to be dispatched through
                # busybox; mkdir -p creates /var/log on first touch.
                "{0} mkdir -p $({0} dirname {1}) && {0} touch {1} && {0} tail -f {1}".format(
                    BUSYBOX,
                    lean_shared.lean_log_file_path(node["service_name"]),
                )
            ],
            "files": {
                NODE_KEY_MOUNT: p2p_keys_artifact,
                HASH_SIG_MOUNT: hash_sig_artifact,
                BUSYBOX_MOUNT: busybox_artifact,
            },
        }
    )
    return plan.add_service(node["service_name"], ServiceConfig(**cfg_kwargs))


def start(plan, node, service, genesis_artifact, hash_sig_artifact):
    service_name = service.name
    log_file = lean_shared.lean_log_file_path(service_name)

    # Use busybox sh for every shell-needing step inside the zeam container.
    # Pre-create /data so zeam can write its RocksDB / LMDB there, and stage
    # the libp2p node key into /network-configs (lean-quickstart's zeam
    # contract has --node-key inside the custom-genesis dir, not in a
    # separate mount).
    plan.exec(
        service_name=service_name,
        recipe=ExecRecipe(
            command=[
                BUSYBOX,
                "sh",
                "-c",
                "{0} mkdir -p {1} {2} && {0} cp {3}/{4}.key {1}/{4}.key".format(
                    BUSYBOX,
                    GENESIS_MOUNT,
                    DATA_DIR,
                    NODE_KEY_MOUNT,
                    node["node_name"],
                ),
            ],
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
                    BUSYBOX,
                    "sh",
                    "-c",
                    "{3} cat > {0}/{1} <<'ZEAM_EOF'\n{2}\nZEAM_EOF".format(
                        GENESIS_MOUNT, filename, read.output, BUSYBOX,
                    ),
                ],
            ),
            description="Staging {0} into {1}".format(filename, service_name),
        )

    cmd_parts = [
        ENTRYPOINT,
        "node",
        "--custom-genesis", GENESIS_MOUNT,
        # zeam's --validator-config accepts either a directory of per-node
        # validator configs OR the literal sentinel `genesis_bootnode`,
        # which tells zeam to derive its validator set from the
        # GENESIS_VALIDATORS list in config.yaml. Pointing at a single
        # file path (lean-quickstart's `validator-config.yaml`) trips
        # zeam's "NotDir" check, so use the sentinel here.
        "--validator-config", "genesis_bootnode",
        "--data-dir", DATA_DIR,
        "--node-id", node["node_name"],
        # zeam (per lean-quickstart's contract) reads --node-key relative to
        # the custom-genesis dir; we staged it there in the prepare step.
        "--node-key", "{0}/{1}.key".format(GENESIS_MOUNT, node["node_name"]),
        "--metrics-enable",
        "--api-port", str(constants.LEAN_API_PORT_NUM),
        "--metrics-port", str(constants.LEAN_METRICS_PORT_NUM),
    ]
    if node["is_aggregator"]:
        cmd_parts.append("--is-aggregator")
    for extra in node["extra_params"]:
        cmd_parts.append(extra)

    nohup_cmd = "{0} nohup {1} >> {2} 2>&1 &".format(
        BUSYBOX,
        " ".join(cmd_parts),
        log_file,
    )
    plan.exec(
        service_name=service_name,
        recipe=ExecRecipe(
            command=[BUSYBOX, "sh", "-c", nohup_cmd],
        ),
        description="Starting zeam binary on {0}".format(service_name),
    )

    api_url = "http://{0}:{1}".format(
        service.ip_address, constants.LEAN_API_PORT_NUM
    )
    metrics_url = "http://{0}:{1}/metrics".format(
        service.ip_address, constants.LEAN_METRICS_PORT_NUM,
    )

    return lean_context.new_lean_context(
        client_name=constants.LEAN_TYPE.zeam,
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
