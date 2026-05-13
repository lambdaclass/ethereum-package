"""
Shared helpers for Lean client launchers.

Every Lean client speaks the same wire protocols (libp2p QUIC + JSON REST +
Prometheus). Keeping the port specs and mountpoint contract in one module
lets per-client launchers stay focused on CLI translation.
"""

constants = import_module("../package_io/constants.star")


def lean_port_specs():
    """Default port spec triple for any Lean client.

    QUIC is the only P2P protocol (no TCP discovery); the API and metrics
    endpoints are plain HTTP. Each Lean client maps these to its own CLI
    flag names (`--gossipsub-port`, `--http-port`, etc.) inside its
    launcher.
    """
    return {
        constants.LEAN_QUIC_PORT_ID: PortSpec(
            number=constants.LEAN_QUIC_PORT_NUM,
            transport_protocol="UDP",
            application_protocol="quic",
            wait=None,
        ),
        constants.LEAN_API_PORT_ID: PortSpec(
            number=constants.LEAN_API_PORT_NUM,
            transport_protocol="TCP",
            application_protocol="http",
            wait=None,
        ),
        constants.LEAN_METRICS_PORT_ID: PortSpec(
            number=constants.LEAN_METRICS_PORT_NUM,
            transport_protocol="TCP",
            application_protocol="http",
            wait=None,
        ),
    }


def lean_log_file_path(service_name):
    """Path inside the container where the Lean client's logs are tailed.

    Stored under /var/log so a single `tail -f` keeps the Kurtosis service
    "alive" while we initialise it; the client itself runs as a backgrounded
    `nohup`. Matches the pattern ReamLabs/pq-devnet-package established.
    """
    return "/var/log/{0}.log".format(service_name)


def lean_tail_logs_cmd(service_name):
    """Initial container command — touches and tails the log file.

    Holds the service open until the actual client binary is started by a
    follow-up `plan.exec`. Without this, Kurtosis would mark the service
    failed before we got a chance to mount the genesis bundle.
    """
    log_file = lean_log_file_path(service_name)
    return ["/bin/sh", "-c", "touch {0} && tail -f {0}".format(log_file)]


def common_cfg_kwargs(node):
    """ServiceConfig kwargs shared between per-client initialize() and start().

    Kurtosis rejects memory/cpu values of 0 (it expects "unset" via the
    *absence* of the kwarg, not via a 0 sentinel). We omit those keys here
    when the participant didn't set them. Per-client launchers add image,
    cmd, entrypoint, and files on top.
    """
    kwargs = {
        "ports": lean_port_specs(),
        "env_vars": node["extra_env_vars"],
        "labels": node["extra_labels"],
        "node_selectors": node["node_selectors"],
        "tolerations": node["tolerations"],
    }
    if node["min_cpu"] > 0:
        kwargs["min_cpu"] = node["min_cpu"]
    if node["max_cpu"] > 0:
        kwargs["max_cpu"] = node["max_cpu"]
    if node["min_mem"] > 0:
        kwargs["min_memory"] = node["min_mem"]
    if node["max_mem"] > 0:
        kwargs["max_memory"] = node["max_mem"]
    return kwargs
