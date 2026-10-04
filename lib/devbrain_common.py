"""devbrain_common — helpers the Python audit scripts in bin/ share.

Imported with the same sys.path pattern lib/day_engine.py uses, resolved from
the script's real path so a symlinked script still finds it.
"""
import os
import subprocess


def read_names(path):
    """Names from a one-per-line config file. '#' starts a comment, so both bare
    names (.allow) and "name  # reason" lines (.excluded) work. A missing file
    is an empty set."""
    names = set()
    if not os.path.isfile(path):
        return names
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            name = line.split("#", 1)[0].strip()
            if name:
                names.add(name)
    return names


def run(cmd, cwd=None, timeout=60):
    """Run a subprocess, never raising. Returns (ok, stdout, stderr)."""
    try:
        proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return proc.returncode == 0, proc.stdout, proc.stderr
    except (OSError, subprocess.SubprocessError) as exc:
        return False, "", str(exc)
