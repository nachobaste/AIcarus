#!/usr/bin/env python3
"""research_promote — raw backlog in, 2-3 decidable proposals out.

The operator's definition of "listo" (interview 2026-08-08): *pocas y profundas* — at
most 2-3 proposals per cycle, each already investigated, with the files it would touch,
at least two options with pros and cons, and effort in nights. They should be able to
decide in about five minutes. The point is to spend less of their time, not to produce
more text.

Two jobs, both deliberately out of the prompt and into code:

  select    which findings earn the expensive deep pass. The criteria are below, in
            the open, so they can be argued with and changed. A ranking hidden in a
            prompt is a ranking nobody can audit.
  validate  whether what came back is actually decidable. The failure mode is a
            second "option" that touches the same files as the first — filler
            dressed as a choice, and the easiest thing to produce when a model is
            told to give two options.

Read-only. Writes nothing; the caller decides what to do with stdout.

Usage:
    ... | research_promote.py select      # backlog  -> the findings to deepen
    ... | research_promote.py validate    # proposals -> the ones that are decidable

Environment:
    RESEARCH_PROMOTE_MAX      how many to promote per cycle (default 3)
    RESEARCH_REPO_ROOT        repo that a proposal's file paths must resolve against
    DEVBRAIN_DIGEST_STALE_DAYS  days a pending proposal can wait before the digest
                              flags it (default 3). Shared with bin/devbrain-digest's
                              Bloqueadas section, set by the same caller, so one
                              number controls staleness for both.
"""
import datetime
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from research_filter import fold, parse_findings  # noqa: E402

# --- the selection criteria, in the open -------------------------------------
# Order matters and reflects the plan: first what unblocks other work, then what
# carries the hardest evidence, then what is smallest. Change these numbers and the
# ranking changes — that is the point of having them here instead of in a prompt.
#
# "Unblocks other work" is not machine-detectable, so it is not guessed: it counts
# only when the finding SAYS so. A finding that does not claim to block anything is
# not treated as if it might.
BLOQUEA_MARKERS = ("bloquea", "impide", "traba", "sin esto", "hasta que se resuelva",
                   "no se puede avanzar", "depende de")
PESO_BLOQUEA = 100      # a declared blocker outranks everything else
PESO_POR_ARCHIVO = 10   # distinct files cited, capped
MAX_ARCHIVOS_CONTADOS = 5
PESO_TAMANO = 10        # smaller is better, never negative


def archivos_de(evidencia):
    """Distinct file paths in an evidencia field, line numbers and backticks off."""
    out = set()
    for cita in evidencia.split(","):
        cita = cita.strip().strip("`").strip()
        if not cita:
            continue
        out.add(cita.rsplit(":", 1)[0] if re.search(r":\d+$", cita) else cita)
    return out


def noches_de(tamano):
    m = re.search(r"\d+(?:[.,]\d+)?", tamano or "")
    return float(m.group(0).replace(",", ".")) if m else 1.0


def score(f):
    porque = (f.get("porque") or "").lower()
    s = PESO_BLOQUEA if any(m in porque for m in BLOQUEA_MARKERS) else 0
    s += PESO_POR_ARCHIVO * min(len(archivos_de(f.get("evidencia", ""))), MAX_ARCHIVOS_CONTADOS)
    s += max(0.0, PESO_TAMANO - noches_de(f.get("tamano", "")))
    return s


def already_promoted(text):
    """Titles that a proposal already claims as its origin.

    Without this the same proposal reaches the operator every night until they act on it,
    which trains him to ignore the section.
    """
    return {ln.split(":", 1)[1].strip()
            for ln in text.splitlines()
            if fold(ln.strip().lstrip("- ").split(":", 1)[0]) == "origen" and ":" in ln}


def do_select():
    text = sys.stdin.read()
    done = already_promoted(text)
    try:
        cap = int(os.environ.get("RESEARCH_PROMOTE_MAX", "3"))
    except ValueError:
        cap = 3

    candidates = [f for f in parse_findings(text)
                  if f.get("titulo") and f["titulo"] not in done
                  and all(f.get(k) for k in ("repo", "evidencia", "porque", "tamano"))]

    # Sorted by score, ties broken by position in the backlog — never by chance, so
    # the same backlog always yields the same picks.
    ordered = sorted(enumerate(candidates), key=lambda p: (-score(p[1]), p[0]))
    chosen = [f for _, f in ordered[:cap]]

    for f in chosen:
        print(f"### {f['titulo']}\n- repo: {f['repo']}\n- evidencia: {f['evidencia']}\n"
              f"- porque: {f['porque']}\n- tamano: {f['tamano']}\n")

    if not chosen:
        print("nada que promover", file=sys.stderr)
    else:
        print(f"promovidos: {len(chosen)} de {len(candidates)} candidatos", file=sys.stderr)
    return 0


# --- validation ---------------------------------------------------------------
def parse_proposals(text):
    props, cur, opt = [], None, None
    for raw in text.splitlines():
        line = raw.rstrip()
        if line.startswith("### "):
            if cur:
                props.append(cur)
            cur, opt = {"titulo": line[4:].strip(), "opciones": [], "cuerpo": []}, None
            continue
        if cur is None:
            continue
        cur["cuerpo"].append(raw)
        if line.startswith("#### "):
            opt = {"nombre": line[5:].strip(), "archivos": set()}
            cur["opciones"].append(opt)
            continue
        m = re.match(r"^\s*-\s*([^:]+?)\s*:\s*(.*)$", line)
        if m and fold(m.group(1)) == "archivos" and opt is not None:
            opt["archivos"] = {p.strip().strip("`") for p in m.group(2).split(",") if p.strip()}
    if cur:
        props.append(cur)
    return props


def do_validate(origen=None):
    root = os.environ.get("RESEARCH_REPO_ROOT", "")
    kept, dropped = [], {"opciones-insuficientes": 0, "opciones-identicas": 0,
                         "sin-anclaje": 0}

    for p in parse_proposals(sys.stdin.read()):
        opciones = [o for o in p["opciones"] if o["archivos"]]
        if len(opciones) < 2:
            dropped["opciones-insuficientes"] += 1
            continue
        # Two options over the same files are one option written twice. The operator
        # cannot choose between them, so the proposal is not decidable.
        if len({frozenset(o["archivos"]) for o in opciones}) < 2:
            dropped["opciones-identicas"] += 1
            continue
        # A proposal names what it would TOUCH, which legitimately includes files it
        # would create — the finding "there is no package.json" can only be answered by
        # a proposal that names one. So a missing path is annotated, not fatal.
        # What IS fatal is a proposal where nothing resolves: that is either about a
        # different repo or invented whole, and either way it is not decidable here.
        todos = set().union(*(o["archivos"] for o in opciones))
        existentes = {a for a in todos if os.path.isfile(os.path.join(root, a))}
        # Anchoring means "in THIS repo". An absolute path defeats os.path.join, so
        # /etc/hosts used to resolve and pass as an anchor. Options that reach into
        # another repo stay allowed — they are often the honest answer — but they
        # cannot be the only thing holding the proposal up.
        real_root = os.path.realpath(root) if root else ""
        dentro = {a for a in existentes
                  if real_root and (os.path.realpath(os.path.join(root, a)) + os.sep)
                  .startswith(real_root + os.sep)}
        if not dentro:
            dropped["sin-anclaje"] += 1
            continue
        p["nuevos"] = todos - existentes
        kept.append(p)

    for p in kept:
        print(f"### {p['titulo']}")
        if origen:
            # Written here, never taken from the model. A misattributed proposal would
            # mark the wrong finding as promoted and the real one would return nightly.
            print(f"- origen: {origen}")
        cuerpo = [ln for ln in p["cuerpo"] if fold(ln.strip().lstrip("- ").split(":", 1)[0]) != "origen"]
        texto = "\n".join(cuerpo).strip()
        # Mark what does not exist yet, so the operator reads "this creates a file" instead of
        # assuming every path named is already there.
        for nuevo in sorted(p.get("nuevos", ()), key=len, reverse=True):
            texto = texto.replace(nuevo, f"{nuevo} (nuevo)")
        print(texto + "\n")

    detail = ", ".join(f"{k}: {v}" for k, v in dropped.items() if v)
    print(f"propuestas: {len(kept)} descartadas: {sum(dropped.values())}"
          + (f" ({detail})" if detail else ""), file=sys.stderr)
    return 0



# --- digest: what reaches the operator's phone at 6am --------------------------
# The number in front of each proposal is load-bearing: plan 250 lets the operator
# reply "dale 2" from Telegram. It must stay exact and stable, so this NEVER goes through
# the AI summarizer that writes the rest of the digest — a model asked to
# "summarize" would feel free to reword or drop it.
DIGEST_LINE_CAP = 140

# The "## Propuestas — YYYY-MM-DD" heading is written once, by do_validate's caller,
# the moment a finding is promoted (see wiki/projects/mejoras-propuestas.md) — a
# real date, not a proxy. Every '### ' proposal block until the next such heading
# was promoted on that date, so age here is exact, unlike Bloqueadas (see
# queue_file_age_days in lib/queue.sh, whose mtime-based age IS a proxy).
_PROPUESTA_HEADER_RE = re.compile(r"^##\s*Propuestas\s*[—-]\s*(\d{4}-\d{2}-\d{2})")
DEFAULT_STALE_DAYS = 3


def _one_line(text, cap=DIGEST_LINE_CAP):
    flat = " ".join((text or "").split())
    return flat if len(flat) <= cap else flat[: cap - 1].rstrip() + "…"


def _stale_days():
    try:
        return int(os.environ.get("DEVBRAIN_DIGEST_STALE_DAYS", str(DEFAULT_STALE_DAYS)))
    except ValueError:
        return DEFAULT_STALE_DAYS


def _dias_esperando(fecha_iso):
    """Days between a '## Propuestas — YYYY-MM-DD' heading and today, or None if
    the heading is missing/malformed (hand-edited backlog) — degrades honestly,
    same principle as the rest of do_digest, instead of guessing an age."""
    if not fecha_iso:
        return None
    try:
        fecha = datetime.date.fromisoformat(fecha_iso)
    except ValueError:
        return None
    return (datetime.date.today() - fecha).days


def _proposal_blocks(text):
    """('titulo', 'origen', body_lines, 'fecha') for every '### ' block that has
    an '- origen:' line — the one marker that distinguishes a promoted proposal
    from a raw finding, both of which use the same '### title' heading. 'fecha'
    is the date of the nearest preceding '## Propuestas — YYYY-MM-DD' heading."""
    blocks, cur = [], None
    fecha_actual = None
    for raw in text.splitlines():
        line = raw.rstrip()
        m_fecha = _PROPUESTA_HEADER_RE.match(line)
        if m_fecha:
            fecha_actual = m_fecha.group(1)
        if line.startswith("### "):
            if cur:
                blocks.append(cur)
            cur = {"titulo": line[4:].strip(), "lines": [], "fecha": fecha_actual}
            continue
        if cur is not None:
            cur["lines"].append(line)
    if cur:
        blocks.append(cur)

    out = []
    for b in blocks:
        origen = esfuerzo = decidida = None
        for ln in b["lines"]:
            m = re.match(r"^\s*-\s*([^:]+?)\s*:\s*(.*)$", ln)
            if not m:
                continue
            key = fold(m.group(1))
            if key == "origen":
                origen = m.group(2).strip()
            elif key == "esfuerzo":
                esfuerzo = m.group(2).strip()
            elif key == "decision":
                decidida = m.group(2).strip()
        if origen is not None:  # only proposals carry this line
            out.append({"titulo": b["titulo"], "origen": origen,
                        "esfuerzo": esfuerzo or "(sin estimar)", "decidida": decidida,
                        "fecha": b.get("fecha")})
    return out


def _porque_by_titulo(text):
    return {f["titulo"]: f.get("porque", "") for f in parse_findings(text)}


def do_digest():
    text = sys.stdin.read()
    porque_de = _porque_by_titulo(text)
    pendientes = [p for p in _proposal_blocks(text) if not p["decidida"]]

    try:
        cap = int(os.environ.get("RESEARCH_DIGEST_MAX", "5"))
    except ValueError:
        cap = 5

    umbral = _stale_days()
    for i, p in enumerate(pendientes[:cap], start=1):
        porque = porque_de.get(p["origen"], "(hallazgo de origen no encontrado)")
        print(f"{i}. {p['titulo']}")
        print(f"   {_one_line(porque)}")
        # Age is appended to the Esfuerzo line, not a line of its own: the digest
        # format is a load-bearing 3-lines-per-proposal contract (see
        # tests/test-research-promote.sh) that plan 250's "dale N" reply depends
        # on staying stable — a 4th line would change nothing about the numbering,
        # but there is no reason to risk it.
        linea = f"Esfuerzo: {p['esfuerzo']}"
        dias = _dias_esperando(p.get("fecha"))
        if dias is not None and dias >= 0:
            palabra = "día" if dias == 1 else "días"
            linea += f" — esperando {dias} {palabra}"
            if dias >= umbral:
                linea = "⚠️ " + linea
        print(f"   {linea}")

    resto = len(pendientes) - cap
    if resto > 0:
        print(f"… y {resto} más, ver mejoras-propuestas.md")
    return 0


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    if mode == "select":
        return do_select()
    if mode == "digest":
        return do_digest()
    if mode == "validate":
        origen = None
        if "--origen" in argv:
            i = argv.index("--origen")
            origen = argv[i + 1] if i + 1 < len(argv) else None
        return do_validate(origen)
    print("usage: research_promote.py select|validate", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
