"""
P2P key generation for Lean consensus nodes.

Each Lean node needs a 32-byte libp2p identity key (the secp256k1 secret that
derives the peer ID and ENR). lean-quickstart writes one such key per node
into `<node_name>.key` as ASCII hex. We reproduce that exact layout so the
genesis tool and every Lean client client-cmds/<client>-cmd.sh contract
matches what they receive at runtime.
"""

OPENSSL_IMAGE = "alpine/openssl"


def generate_node_keys(plan, node_names):
    """Generate one 32-byte hex P2P key per node.

    The keys are written to `/keys/<node_name>.key` inside the OpenSSL helper
    container and exported as a single Kurtosis files artifact (`lean-node-keys`)
    so every Lean client mounts the same directory and reads its own key by
    name. Returns (artifact_name, {node_name: hex_string}).

    The hex strings are also returned in-memory because the genesis tool needs
    them to compute peer IDs / ENRs for `nodes.yaml` *before* the Lean clients
    are started.
    """
    # `tr -d` strips OpenSSL's trailing newline; without it `nodes.yaml`'s
    # peer-id derivation downstream sees an extra byte and computes the wrong
    # libp2p identity.
    script_parts = ["set -eu", "mkdir -p /keys"]
    for name in node_names:
        script_parts.append(
            "openssl rand -hex 32 | tr -d '\\n' > /keys/{0}.key".format(name)
        )
    # Dump everything to stdout so we can capture the keys without a second
    # round-trip. `printf '%s=%s\\n'` keeps the parser trivial.
    for name in node_names:
        script_parts.append(
            "printf '%s=%s\\n' '{0}' \"$(cat /keys/{0}.key)\"".format(name)
        )
    script = "\n".join(script_parts)

    result = plan.run_sh(
        run=script,
        image=OPENSSL_IMAGE,
        store=[
            StoreSpec(src="/keys", name="lean-node-keys"),
        ],
        description="Generating Lean P2P node keys",
    )

    keys_by_name = {}
    for line in result.output.strip().split("\n"):
        if "=" not in line:
            continue
        name, hex_value = line.split("=", 1)
        keys_by_name[name.strip()] = hex_value.strip()

    return struct(
        artifact_name=result.files_artifacts[0],
        keys=keys_by_name,
    )
