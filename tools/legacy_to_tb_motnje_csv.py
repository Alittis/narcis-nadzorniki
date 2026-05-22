"""Convert assets/legacy/notranjski_park_2025.json into TB_MOTNJE-shaped CSVs.

See project/ARCHITECTURE.md §12 for the target schema, and
tools/import_notranjski_csv.py for the upstream conversion that produced the
JSON from the Formidable export.

Usage:
    python3 tools/legacy_to_tb_motnje_csv.py \\
        --input assets/legacy/notranjski_park_2025.json \\
        --output-dir tools/legacy_csv_out \\
        --org-id <int>

Output (in --output-dir):
    TB_MOTNJE.csv                  — one row per disturbance, columns match
                                      the schema 1:1 (lowercased headers).
    TB_MOTNJE_TIPI_DOGODKA.csv     — junction (motnja_id, skupina_koda, tip_koda)
                                      for legacy display names that resolved
                                      against the codebook.
    TB_MOTNJE_OPAZOVALCI.csv       — junction (motnja_id, ime_opazovalca,
                                      uporabnik_id=NULL).
    TB_MOTNJE_FOTO_urls.csv        — SIDECAR (NOT a direct TB_MOTNJE_FOTO load):
                                      (foto_id, motnja_id, url, mime_type,
                                      velikost=NULL, ustvarjen_od, ustvarjen).
                                      A follow-up step must fetch each url,
                                      compute velikost, and INSERT into
                                      TB_MOTNJE_FOTO with the BLOB bytes.
    OBSERVER_TO_EMAIL_MAP.csv      — proposed observer→email mapping. Re-runs
                                      respect manual edits (the file is read
                                      back as input on subsequent runs).
    UNMATCHED_TYPES_REPORT.csv     — every (group, type) display-name pair that
                                      didn't resolve against the codebook; the
                                      same values are concatenated into the
                                      record's PREDLOG_TIPA so the information
                                      isn't lost.

Design choices:
- MOTNJA_ID and FOTO_ID are deterministic uuid5 values, so re-runs produce
  byte-identical output and the load step is idempotent across iterations.
- Author email is synthesized per observer (ASCII-folded, lowercased, dotted)
  on first run; the user reviews and edits OBSERVER_TO_EMAIL_MAP.csv between
  runs.
- Legacy `categoriesByGroup` is free-text; pairs that match the codebook by
  display name (read live from tools/ords/disturbance_codebook_seed.sql) land
  in the junction CSV. Pairs that don't match land in PREDLOG_TIPA verbatim,
  semicolon-joined, truncated at 500 chars to fit the schema.
- NATANCNOST_LOK is mapped from the Slovene long form to the schema CHECK
  values; NULL defaults to 'Približna' (OLC-decoded points are inherently
  coarse).
- UKREPANJE is unconstrained free-text VARCHAR2(50); we keep actionTaken
  verbatim (truncated) when non-null, else fall back to --default-ukrepanje.
- STATUS_OBRAVNAVE defaults to 'Zaključeno' on the rationale that imported
  historical observations are not actionable workflows; override via flag.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import unicodedata
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional


# Stable namespace for uuid5 derivation. Changing this invalidates idempotency
# of prior loads — only do it if you mean to.
NAMESPACE = uuid.UUID("8a3e5d2e-7c2e-4d3a-9b0e-6a9c5e7f1d4b")

SKUPINA_RE = re.compile(r"seed_skupina\('(\d+)',\s*'([^']+)'\)")
TIP_RE = re.compile(r"seed_tip\('(\d+)',\s*'([^']+)',\s*'([^']+)'")

ACCURACY_MAP = {
    "Lokacija natančna": "Natančna",
    "Lokacija približna": "Približna",
}

# Observer names whose records should be dropped entirely. Currently just the
# manual "test test" smoke entries from the upstream Formidable form.
DROP_OBSERVERS: set[str] = {"test test"}

# High-confidence rewrites for legacy (group, type) display-name pairs that
# don't resolve against the live codebook. Restricted to typos, singular/plural
# variants, and one cross-group migration (Kopalci entries that were filed
# under Sprehajalci because the upstream form didn't have a Kopalci group).
# Ambiguous or free-text legacy values are intentionally left for PREDLOG_TIPA.
TYPE_ALIASES: dict[tuple[str, str], tuple[str, str]] = {
    ("Kmetijstvo", "Mulčanje"): ("Kmetijstvo", "Mulčenje"),
    ("Vožnja v naravi", "Traktor"): ("Vožnja v naravi", "Traktorji"),
    ("Vožnja v naravi", "Teaktor"): ("Vožnja v naravi", "Traktorji"),
    ("Vožnja po cestah/kolovozih", "Avtodom"): ("Vožnja po cestah/kolovozih", "Avtodomi"),
    ("Plovba", "Surf"): ("Plovba", "Surf / deska"),
    ("Objekti", "Kolesatska downhil steza"): ("Objekti", "Kolesarska downhill steza"),
    ("Sprehajalci", "Fotograf ali ribič"): ("Sprehajalci", "Fotograf"),
    ("Sprehajalci", "Detektoraž"): ("Sprehajalci", "Detektorist"),
    ("Kmetijstvo", "Sekanje mejice"): ("Kmetijstvo", "Odstranjevanje mejic"),
    ("Kmetijstvo", "Melioracija skal na travniku"): ("Kmetijstvo", "Melioracija travnika"),
    ("Ribolov", "Ob colnu"): ("Ribolov", "Ribolov iz čolna"),
    ("Sprehajalci", "Kopalci"): ("Kopalci", "Kopalci"),
    ("Sprehajalci", "Kopalec"): ("Kopalci", "Kopalci"),
}


def load_codebook(seed_path: Path) -> tuple[dict[str, str], dict[tuple[str, str], str]]:
    """Parse the codebook seed for (group_name → group_code) and
    ((group_code, type_name) → type_code) lookups.
    """
    text = seed_path.read_text(encoding="utf-8")
    group_code_to_name = {m.group(1): m.group(2) for m in SKUPINA_RE.finditer(text)}
    group_name_to_code = {v: k for k, v in group_code_to_name.items()}
    type_lookup = {(m.group(1), m.group(3)): m.group(2) for m in TIP_RE.finditer(text)}
    return group_name_to_code, type_lookup


def slugify_observer(name: str) -> str:
    n = unicodedata.normalize("NFKD", name)
    n = "".join(ch for ch in n if not unicodedata.combining(ch))
    n = n.lower().strip()
    parts = [p for p in re.split(r"\s+", n) if p]
    return ".".join(parts) if parts else "unknown"


def load_or_seed_email_map(
    observers: list[str], path: Path, domain: str
) -> dict[str, dict[str, str]]:
    """Return {observer_name: {"email": ..., "display_name": ...}}.

    `display_name` is optional and empty by default — when non-empty it
    overrides the verbatim source name as `TB_MOTNJE_OPAZOVALCI.ime_opazovalca`.
    Use it to fix case-variant or missing-diacritic source spellings.
    """
    out: dict[str, dict[str, str]] = {}
    if path.exists():
        with path.open(encoding="utf-8", newline="") as f:
            for row in csv.DictReader(f):
                name = (row.get("observer_name") or "").strip()
                if name:
                    out[name] = {
                        "email": (row.get("email") or "").strip(),
                        "display_name": (row.get("display_name") or "").strip(),
                    }
    for o in observers:
        existing = out.get(o) or {}
        if not existing.get("email"):
            existing["email"] = f"{slugify_observer(o)}@{domain}"
        existing.setdefault("display_name", "")
        out[o] = existing
    return out


def write_email_map(email_map: dict[str, dict[str, str]], path: Path) -> None:
    with path.open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["observer_name", "email", "display_name"])
        for name in sorted(email_map):
            entry = email_map[name]
            w.writerow([name, entry.get("email", ""), entry.get("display_name", "")])


def to_natancnost(value: Optional[str]) -> str:
    if value is None:
        return "Približna"
    return ACCURACY_MAP.get(value, "Približna")


def to_oracle_ts(value: Optional[str]) -> str:
    if not value:
        return ""
    try:
        dt = datetime.fromisoformat(value)
    except ValueError:
        return ""
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def truncate(s: str, n: int) -> str:
    return s if len(s) <= n else s[:n]


def mime_from_url(url: str) -> str:
    lower = url.lower()
    if lower.endswith((".jpg", ".jpeg")):
        return "image/jpeg"
    if lower.endswith(".png"):
        return "image/png"
    if lower.endswith(".webp"):
        return "image/webp"
    if lower.endswith((".heic", ".heif")):
        return "image/heic"
    return "image/jpeg"  # WordPress upload pipeline serves jpeg by convention


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, type=Path)
    ap.add_argument("--output-dir", required=True, type=Path)
    ap.add_argument(
        "--codebook-seed",
        default=Path("tools/ords/disturbance_codebook_seed.sql"),
        type=Path,
    )
    ap.add_argument(
        "--org-id",
        type=int,
        required=True,
        help="narcis_organizacije.id for Notranjski regijski park",
    )
    ap.add_argument("--email-domain", default="notranjski-park.si")
    ap.add_argument("--default-ukrepanje", default="Evidentiranje")
    ap.add_argument(
        "--status-obravnave",
        default="Zaključeno",
        choices=["Odprto", "V obravnavi", "Zaključeno", "Predano drugi službi"],
    )
    args = ap.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)

    payload = json.loads(args.input.read_text(encoding="utf-8"))
    records = payload["records"]

    group_name_to_code, type_lookup = load_codebook(args.codebook_seed)

    observers = sorted(
        {r["observer"] for r in records
         if r.get("observer") and r["observer"] not in DROP_OBSERVERS}
    )
    email_map_path = args.output_dir / "OBSERVER_TO_EMAIL_MAP.csv"
    email_map = load_or_seed_email_map(observers, email_map_path, args.email_domain)
    write_email_map(email_map, email_map_path)

    motnje_cols = [
        "motnja_id", "org_id", "geo_sirina", "geo_dolzina", "natancnost_lok",
        "cas_opazovanja", "opis", "ukrepanje", "zakonska_podlaga",
        "status_obravnave", "predlog_tipa", "obhod_id",
        "ustvarjen_od", "ustvarjen", "spremenjen_od", "spremenjen",
    ]
    tipi_cols = ["motnja_id", "skupina_koda", "tip_koda"]
    opaz_cols = ["motnja_id", "ime_opazovalca", "uporabnik_id"]
    foto_cols = [
        "foto_id", "motnja_id", "url", "mime_type", "velikost",
        "ustvarjen_od", "ustvarjen",
    ]
    unmatched_cols = ["motnja_id", "source_id", "group_name", "type_name"]

    paths = {
        "motnje": args.output_dir / "TB_MOTNJE.csv",
        "tipi": args.output_dir / "TB_MOTNJE_TIPI_DOGODKA.csv",
        "opaz": args.output_dir / "TB_MOTNJE_OPAZOVALCI.csv",
        "foto": args.output_dir / "TB_MOTNJE_FOTO_urls.csv",
        "unmatched": args.output_dir / "UNMATCHED_TYPES_REPORT.csv",
    }

    matched_pairs = 0
    unmatched_pairs = 0
    photo_rows = 0
    written_motnje = 0
    dropped_records = 0

    with paths["motnje"].open("w", encoding="utf-8", newline="") as fm, \
         paths["tipi"].open("w", encoding="utf-8", newline="") as ft, \
         paths["opaz"].open("w", encoding="utf-8", newline="") as fo, \
         paths["foto"].open("w", encoding="utf-8", newline="") as ffoto, \
         paths["unmatched"].open("w", encoding="utf-8", newline="") as fu:

        wm = csv.DictWriter(fm, fieldnames=motnje_cols); wm.writeheader()
        wt = csv.DictWriter(ft, fieldnames=tipi_cols); wt.writeheader()
        wo = csv.DictWriter(fo, fieldnames=opaz_cols); wo.writeheader()
        wfoto = csv.DictWriter(ffoto, fieldnames=foto_cols); wfoto.writeheader()
        wu = csv.DictWriter(fu, fieldnames=unmatched_cols); wu.writeheader()

        for r in records:
            observer = (r.get("observer") or "").strip()
            if observer in DROP_OBSERVERS:
                dropped_records += 1
                continue

            source_id = r.get("sourceId") or ""
            uuid_key = (
                f"notranjski-{source_id or r.get('observedAt') or ''}-"
                f"{r['latitude']}-{r['longitude']}"
            )
            motnja_id = str(uuid.uuid5(NAMESPACE, uuid_key))

            entry = email_map.get(observer) or {}
            email = entry.get("email") or f"legacy@{args.email_domain}"
            display_name = entry.get("display_name") or observer

            cas_ts = to_oracle_ts(r.get("observedAt"))

            predlog_parts: list[str] = []
            emitted_pairs: set[tuple[str, str]] = set()
            for g_name, types in (r.get("categoriesByGroup") or {}).items():
                for t_name in types:
                    alias = TYPE_ALIASES.get((g_name, t_name))
                    resolved_group, resolved_type = alias if alias else (g_name, t_name)
                    g_code = group_name_to_code.get(resolved_group)
                    if g_code is not None and (g_code, resolved_type) in type_lookup:
                        pair = (g_code, type_lookup[(g_code, resolved_type)])
                        if pair in emitted_pairs:
                            continue
                        emitted_pairs.add(pair)
                        wt.writerow({
                            "motnja_id": motnja_id,
                            "skupina_koda": pair[0],
                            "tip_koda": pair[1],
                        })
                        matched_pairs += 1
                    else:
                        predlog_parts.append(f"{g_name} / {t_name}")
                        wu.writerow({
                            "motnja_id": motnja_id,
                            "source_id": source_id,
                            "group_name": g_name,
                            "type_name": t_name,
                        })
                        unmatched_pairs += 1

            predlog = truncate("; ".join(predlog_parts), 500)

            action_taken = (r.get("actionTaken") or "").strip()
            ukrepanje = truncate(action_taken or args.default_ukrepanje, 50)

            wm.writerow({
                "motnja_id": motnja_id,
                "org_id": args.org_id,
                "geo_sirina": f"{r['latitude']:.7f}",
                "geo_dolzina": f"{r['longitude']:.7f}",
                "natancnost_lok": to_natancnost(r.get("locationAccuracy")),
                "cas_opazovanja": cas_ts,
                "opis": r.get("description") or "",
                "ukrepanje": ukrepanje,
                "zakonska_podlaga": "",
                "status_obravnave": args.status_obravnave,
                "predlog_tipa": predlog,
                "obhod_id": "",
                "ustvarjen_od": email,
                "ustvarjen": cas_ts,
                "spremenjen_od": "",
                "spremenjen": "",
            })
            written_motnje += 1

            if observer:
                wo.writerow({
                    "motnja_id": motnja_id,
                    "ime_opazovalca": truncate(display_name, 200),
                    "uporabnik_id": "",
                })

            for url in r.get("photoUrls") or []:
                foto_id = str(uuid.uuid5(NAMESPACE, f"notranjski-foto-{motnja_id}-{url}"))
                wfoto.writerow({
                    "foto_id": foto_id,
                    "motnja_id": motnja_id,
                    "url": url,
                    "mime_type": mime_from_url(url),
                    "velikost": "",
                    "ustvarjen_od": email,
                    "ustvarjen": cas_ts,
                })
                photo_rows += 1

    print(f"Wrote {written_motnje} rows to {paths['motnje']}")
    print(f"Dropped {dropped_records} rows on observer blacklist {sorted(DROP_OBSERVERS)}")
    print(f"Wrote {matched_pairs} matched type pairs to {paths['tipi']}")
    print(f"Wrote {unmatched_pairs} unmatched type pairs to {paths['unmatched']} "
          f"(also concatenated into PREDLOG_TIPA)")
    print(f"Wrote {photo_rows} photo URL rows to {paths['foto']}")
    print(f"Observer→email map: {email_map_path} ({len(observers)} observers)")


if __name__ == "__main__":
    main()
