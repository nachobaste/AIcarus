"""config_dir() / config_path(name) -- the Python twin of lib/config.sh.

$DEVBRAIN_CONFIG_DIR, default <root>/config, with <root> defaulting to this repo.
A per-file variable still wins: callers use this only as that variable's default.
"""
import os

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def config_dir(root=None):
    return os.environ.get("DEVBRAIN_CONFIG_DIR") or os.path.join(root or REPO, "config")


def config_path(name, root=None):
    return os.path.join(config_dir(root), name)
