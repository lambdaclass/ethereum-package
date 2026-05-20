"""
P2P key generation for Lean consensus nodes.

Each Lean node needs a 32-byte libp2p identity key (the secp256k1 secret that
derives the peer ID and ENR). lean-quickstart writes one such key per node
into `<node_name>.key` as ASCII hex. We reproduce that exact layout so the
genesis tool and every Lean client's CLI receive the same files at runtime.

We deliberately do NOT read the generated key values back into Starlark — in
Kurtosis, `plan.run_sh(...).output` is a runtime future that only materialises
when the plan is applied, so it can't be used to drive Starlark interpretation
(dict lookups, loops, etc.). Instead we export the keys as a files artifact
and let *downstream containers* read each key from `/keys/<node>.key` when
they need it.
"""

OPENSSL_IMAGE = "alpine/openssl"

KEYS_ARTIFACT_NAME = "lean-node-keys"
KEYS_MOUNT_INSIDE_GENERATOR = "/keys"


def generate_node_keys(plan, node_names):
    """Generate one 32-byte hex P2P key per node into a single artifact.

    Returns the artifact name. Reading individual key values back into
    Starlark is not supported — see the module docstring.
    """
    # `tr -d` strips OpenSSL's trailing newline; without it, the genesis
    # tool's libp2p peer ID derivation downstream sees an extra byte and
    # computes the wrong identity, which then mismatches what the running
    # client derives.
    script_parts = ["set -eu", "mkdir -p {0}".format(KEYS_MOUNT_INSIDE_GENERATOR)]
    for name in node_names:
        script_parts.append(
            "openssl rand -hex 32 | tr -d '\\n' > {0}/{1}.key".format(
                KEYS_MOUNT_INSIDE_GENERATOR, name
            )
        )
    script = "\n".join(script_parts)

    plan.run_sh(
        run=script,
        image=OPENSSL_IMAGE,
        store=[StoreSpec(src=KEYS_MOUNT_INSIDE_GENERATOR, name=KEYS_ARTIFACT_NAME)],
        description="Generating Lean P2P node keys ({0} nodes)".format(len(node_names)),
    )
    return KEYS_ARTIFACT_NAME
