#!/usr/bin/env python3
"""day_engine — the motor behind the day-shift: a decision on a proposal, this
writes it as a plan or discards it. Shared by bin/devbrain-day (the terminal
interface) and a potential Telegram approval path — one implementation, so the two
paths cannot validate differently.

Every proposal is identified by its TITLE, never by its position in a list. A list
position is a snapshot; the backlog can change between when a title was shown and
when a decision on it is applied (a whole interactive walkthrough, or hours between
a morning digest and a "dale 2" from Telegram). Resolving "which numbered item" to
a title is the CALLER's job, done once, close to wherever the human typed the
number. This engine never guesses which proposal a stale number still points to.

Read-only except for its own stdout: it never writes a file, never touches git. The
caller (lib/day.sh) does that, the same split already used by research_filter and
research_promote.

Usage (backlog text always via stdin):
    day_engine.py list
    day_engine.py show <titulo>
    day_engine.py render <titulo> [--opcion A|B]
    day_engine.py mark <titulo> dale|no [--motivo TEXT]

Environment:
    RESEARCH_ALLOWFILE  devbrain-projects.allow path (render only)
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from research_filter import fold  # noqa: E402

SLUG_MAX = 48


def slugify(text):
    import unicodedata
    stripped = unicodedata.normalize("NFKD", text.lower())
    ascii_only = "".join(c for c in stripped if not unicodedata.combining(c))
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_only).strip("-")
    return slug[:SLUG_MAX].rstrip("-") or "propuesta"


def parse_backlog(text):
    """Every '### ' block that carries an '- origen:' line — the same marker
    research_promote uses to tell a proposal apart from a raw finding, which shares
    the same '### title' heading. Each block keeps its raw lines (for `show` and for
    splicing in `mark`) and its options in order, each with its own raw lines (for
    `render`, which needs an option's pros/contras verbatim, not just its files)."""
    blocks, cur = [], None
    for raw in text.splitlines():
        line = raw.rstrip()
        if line.startswith("### "):
            if cur:
                blocks.append(cur)
            cur = {"titulo": line[4:].strip(), "meta": {}, "opciones": [], "raw": [raw]}
            continue
        if cur is None:
            continue
        cur["raw"].append(raw)
        if line.startswith("#### "):
            cur["opciones"].append({"nombre": line[5:].strip(), "archivos": set(), "raw": [raw]})
            continue
        if cur["opciones"]:
            opt = cur["opciones"][-1]
            opt["raw"].append(raw)
            m = re.match(r"^\s*-\s*([^:]+?)\s*:\s*(.*)$", line)
            if m and fold(m.group(1)) == "archivos":
                opt["archivos"] = {p.strip().strip("`") for p in m.group(2).split(",") if p.strip()}
            continue
        m = re.match(r"^\s*-\s*([^:]+?)\s*:\s*(.*)$", line)
        if m:
            cur["meta"][fold(m.group(1))] = m.group(2).strip()
    if cur:
        blocks.append(cur)
    return [b for b in blocks if "origen" in b["meta"]]


def pending(blocks):
    return [b for b in blocks if "decision" not in b["meta"]]


def find_pending(blocks, titulo):
    for b in pending(blocks):
        if b["titulo"] == titulo:
            return b
    return None


def cmd_list():
    for b in pending(parse_backlog(sys.stdin.read())):
        print(b["titulo"])
    return 0


def cmd_show(titulo):
    b = find_pending(parse_backlog(sys.stdin.read()), titulo)
    if not b:
        print(f"day_engine: no hay una propuesta pendiente con ese titulo: {titulo!r}", file=sys.stderr)
        return 3
    print("\n".join(b["raw"]).rstrip())
    return 0


def is_self_repo(repo, allowfile):
    """Is `repo` this devbrain installation's own repo (the same directory that
    devbrain-projects.allow lives in), rather than a project it manages? Structural
    check, not a hardcoded name — it works no matter what you called your checkout.
    devbrain-projects.excluded should also list this repo explicitly with a reason,
    but this check protects `render` even if someone forgets that line."""
    if not allowfile:
        return False
    root = os.path.dirname(os.path.abspath(allowfile))
    return repo == os.path.basename(root)


def allowed_repo(repo, allowfile):
    # This devbrain installation's own repo is refused by structural check,
    # independently of the allowlist file — that file is editable by anyone, and
    # this repo holds the security limits an unattended agent runs under.
    if is_self_repo(repo, allowfile):
        return False
    if not allowfile or not os.path.isfile(allowfile):
        return False
    with open(allowfile, encoding="utf-8") as fh:
        listed = {ln.strip() for ln in fh if ln.strip() and not ln.strip().startswith("#")}
    return repo in listed


def cmd_render(titulo, opcion_letra):
    b = find_pending(parse_backlog(sys.stdin.read()), titulo)
    if not b:
        print(f"day_engine: no hay una propuesta pendiente con ese titulo: {titulo!r}", file=sys.stderr)
        return 4
    repo = b["meta"].get("repo", "")
    allowfile = os.environ.get("RESEARCH_ALLOWFILE", "")
    if not allowed_repo(repo, allowfile):
        print(f"day_engine: repo no habilitado para aprobar: {repo!r} "
              f"(ver {allowfile or 'RESEARCH_ALLOWFILE sin definir'})", file=sys.stderr)
        return 3
    if not b["opciones"]:
        print(f"day_engine: la propuesta {titulo!r} no tiene opciones para elegir", file=sys.stderr)
        return 4

    if opcion_letra:
        idx = ord(opcion_letra.upper()) - ord("A")
        if idx < 0 or idx >= len(b["opciones"]):
            print(f"day_engine: opcion invalida: {opcion_letra!r}", file=sys.stderr)
            return 2
    else:
        idx = 0  # default: the first/recommended option
    opcion = b["opciones"][idx]
    letra = chr(ord("A") + idx)

    archivos = ", ".join(sorted(opcion["archivos"])) or "(sin archivos declarados)"
    riesgos = b["meta"].get("riesgos", "(ninguno declarado por la propuesta)")
    verificar = b["meta"].get("verificar", "(no especificado por la propuesta)")
    origen = b["meta"].get("origen", "(sin hallazgo de origen)")
    opcion_detalle = "\n".join(opcion["raw"]).strip()

    body = f"""{b['titulo']}

## Contexto

Propuesta del research shift (`devbrain-research` → `devbrain-day`), generada a partir
del hallazgo "{origen}". Opción elegida: {letra} — {opcion['nombre']}.

## Qué hacer

Archivos afectados: {archivos}

{opcion_detalle}

## Cómo verificar

{verificar}

## Riesgos

{riesgos}

## Recordatorio

Generado por `devbrain-day` a partir de una propuesta ya aprobada ("dale").
No es un plan escrito a mano — si algo no cierra contra el código real, priorizar lo
que se observa en el repo por sobre lo que la propuesta asumió.
"""
    print(f"repo: {repo}")
    print(f"slug: {slugify(b['titulo'])}")
    print("---")
    print(body)
    return 0


def cmd_mark(titulo, decision, motivo):
    text = sys.stdin.read()
    blocks = parse_backlog(text)
    b = find_pending(blocks, titulo)
    if not b:
        print(f"day_engine: no hay una propuesta pendiente con ese titulo: {titulo!r} "
              "(ya decidida, o no existe)", file=sys.stderr)
        return 3

    if decision == "dale":
        dec_line = "- decision: aprobada"
    elif decision == "no":
        if not motivo or not motivo.strip():
            print("day_engine: descartar una propuesta requiere --motivo (sin motivo, "
                  "el research repite el mismo error toda la semana)", file=sys.stderr)
            return 2
        dec_line = f"- decision: descartada — {motivo.strip()}"
    else:
        print(f"day_engine: decision desconocida: {decision!r} (dale|no)", file=sys.stderr)
        return 2

    lines = text.splitlines()
    # Locate the block's raw lines within the full text by matching its exact sequence
    # once — a proposal's raw block is unique by construction (parse_backlog built it
    # from a single contiguous run of lines), so this anchors reliably even if two
    # proposals happen to share a title (the origen line still disambiguates them,
    # since sys.stdin.read() -> parse -> pending -> find_pending already picked one
    # specific block object, not just a name).
    block_text = "\n".join(b["raw"])
    joined = "\n".join(lines)
    start = joined.find(block_text)
    if start < 0:
        print("day_engine: no se pudo ubicar el bloque exacto de la propuesta en el "
              "backlog (¿se edito a mano entre el parseo y ahora?)", file=sys.stderr)
        return 5
    insertion = start + len(b["raw"][0])  # right after the '### titulo' line
    new_text = joined[:insertion] + "\n" + dec_line + joined[insertion:]
    print(new_text)
    return 0


def main(argv):
    if len(argv) < 2:
        print("usage: day_engine.py list|show|render|mark ...", file=sys.stderr)
        return 2
    cmd = argv[1]
    rest = argv[2:]

    if cmd == "list":
        return cmd_list()
    if cmd == "show":
        if not rest:
            print("usage: day_engine.py show <titulo>", file=sys.stderr)
            return 2
        return cmd_show(rest[0])
    if cmd == "render":
        if not rest:
            print("usage: day_engine.py render <titulo> [--opcion A|B]", file=sys.stderr)
            return 2
        opcion = None
        if "--opcion" in rest:
            i = rest.index("--opcion")
            opcion = rest[i + 1] if i + 1 < len(rest) else None
            del rest[i:i + 2]
        return cmd_render(rest[0], opcion)
    if cmd == "mark":
        if len(rest) < 2:
            print("usage: day_engine.py mark <titulo> dale|no [--motivo TEXT]", file=sys.stderr)
            return 2
        motivo = None
        if "--motivo" in rest:
            i = rest.index("--motivo")
            motivo = rest[i + 1] if i + 1 < len(rest) else None
            del rest[i:i + 2]
        return cmd_mark(rest[0], rest[1], motivo)

    print(f"day_engine.py: comando desconocido: {cmd!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
