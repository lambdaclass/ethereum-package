"""
Per-node Lean context.

Returned by every `lean/<client>/<client>_launcher.start_*` and consumed by
Prometheus / Grafana / dora / etc. to discover the running Lean nodes.
"""


def new_lean_context(
    client_name,
    service_name,
    ip_address,
    quic_port,
    api_port,
    metrics_port,
    api_url,
    metrics_url,
    metrics_info=None,
):
    return struct(
        client_name=client_name,
        service_name=service_name,
        ip_address=ip_address,
        quic_port=quic_port,
        api_port=api_port,
        metrics_port=metrics_port,
        api_url=api_url,
        metrics_url=metrics_url,
        metrics_info=metrics_info,
    )
