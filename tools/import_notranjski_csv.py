"""Convert a Formidable-form CSV export from nadzor.notranjski-park.si into
a read-only asset JSON consumed by the Flutter app as historical context.

Usage:
    python3 tools/import_notranjski_csv.py \\
        --input "/path/to/formidable_entries.csv" \\
        --output assets/legacy/notranjski_park_2025.json

Design notes:
- Records are treated as READ-ONLY historical context, not live data.
- Free-text category values are preserved as-is (no mapping to our codebook)
  so displayed chips match what the observer actually typed.
- Rows with Entry Status == "3" (drafts / incomplete) are dropped.
- PII-ish fields (email, IP, wp user ids) are dropped.
- Lat/lon: use explicit columns when present; otherwise decode the
  Plus Code from the `Lokacija` cell against a Notranjski park reference.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from datetime import date, datetime
from pathlib import Path
from typing import Optional

from openlocationcode import openlocationcode as olc

PLUS_CODE_RE = re.compile(r"^[2-9CFGHJMPQRVWX]{4,6}\+[2-9CFGHJMPQRVWX]{2,3}\b")
OLC_REFERENCE = (45.79, 14.36)  # Cerknica; Plus Code short-form recovery anchor.

# Column indices (0-based) in the Formidable CSV export.
COL_FIRST_NAME = 0
COL_LAST_NAME = 1
COL_DATE = 3
COL_TIME = 4
COL_ACTION_TAKEN = 19
COL_DESCRIPTION = 20
COL_PHOTOS = 21
COL_LOCATION_TEXT = 22
COL_LAT = 23
COL_LON = 24
COL_ACCURACY = 25
COL_ENTRY_STATUS = 31
COL_SOURCE_ID = 33

# CSV column -> our app's group name.
GROUP_COLUMNS = {
    5: "Sprehajalci",
    6: "Vožnja v naravi",
    7: "Vožnja po cestah/kolovozih",
    8: "Plovba",
    9: "Zrakoplovi",
    10: "Taborjenje",
    11: "Kadavri in poškodovane živali",
    12: "Ribolov",
    13: "Vojska",
    14: "Lov",
    15: "Kmetijstvo",
    16: "Vode",
    17: "Odlagališča",
    18: "Objekti",
}


def cell(row: list[str], idx: int) -> str:
    return row[idx].strip() if idx < len(row) else ""


def parse_datetime(d: str, t: str) -> Optional[str]:
    if not d:
        return None
    try:
        parsed_date = datetime.strptime(d, "%Y-%m-%d").date()
    except ValueError:
        return None
    parsed_time = None
    for fmt in ("%H:%M:%S", "%H:%M"):
        try:
            parsed_time = datetime.strptime(t, fmt).time()
            break
        except ValueError:
            continue
    if parsed_time is None:
        return datetime.combine(parsed_date, datetime.min.time()).isoformat()
    return datetime.combine(parsed_date, parsed_time).isoformat()


def split_multi(cell_value: str) -> list[str]:
    if not cell_value:
        return []
    return [p.strip() for p in cell_value.split(",") if p.strip()]


def try_decode_plus_code(location_text: str) -> Optional[tuple[float, float]]:
    if not location_text:
        return None
    m = PLUS_CODE_RE.match(location_text)
    if not m:
        return None
    code = m.group(0)
    try:
        if olc.isFull(code):
            area = olc.decode(code)
        elif olc.isShort(code):
            full = olc.recoverNearest(code, *OLC_REFERENCE)
            area = olc.decode(full)
        else:
            return None
    except Exception:
        return None
    return (area.latitudeCenter, area.longitudeCenter)


def parse_float(s: str) -> Optional[float]:
    if not s:
        return None
    try:
        return float(s)
    except ValueError:
        return None


def resolve_coords(row: list[str]) -> tuple[Optional[float], Optional[float], Optional[str]]:
    lat = parse_float(cell(row, COL_LAT))
    lon = parse_float(cell(row, COL_LON))
    if lat is not None and lon is not None:
        return lat, lon, "explicit"
    decoded = try_decode_plus_code(cell(row, COL_LOCATION_TEXT))
    if decoded:
        return decoded[0], decoded[1], "plusCode"
    return None, None, None


def convert(input_path: Path, output_path: Path) -> dict:
    kept = 0
    dropped_draft = 0
    dropped_nocoords = 0
    dropped_nocategory = 0
    records = []

    with input_path.open(encoding="utf-8", newline="") as f:
        reader = csv.reader(f, delimiter=";", quotechar='"')
        next(reader, None)  # skip header
        for row in reader:
            if cell(row, COL_ENTRY_STATUS) == "3":
                dropped_draft += 1
                continue

            categories_by_group: dict[str, list[str]] = {}
            for col, group_name in GROUP_COLUMNS.items():
                values = split_multi(cell(row, col))
                if values:
                    categories_by_group[group_name] = values

            if not categories_by_group:
                dropped_nocategory += 1
                continue

            lat, lon, source = resolve_coords(row)
            if lat is None or lon is None:
                dropped_nocoords += 1
                continue

            observed_at = parse_datetime(cell(row, COL_DATE), cell(row, COL_TIME))
            observer = " ".join(
                part for part in (cell(row, COL_FIRST_NAME), cell(row, COL_LAST_NAME)) if part
            ) or None
            photos_raw = cell(row, COL_PHOTOS)
            photo_urls = [p.strip() for p in photos_raw.split(",") if p.strip().startswith("http")]

            records.append({
                "sourceId": cell(row, COL_SOURCE_ID) or None,
                "observedAt": observed_at,
                "observer": observer,
                "latitude": round(lat, 6),
                "longitude": round(lon, 6),
                "locationSource": source,
                "locationAccuracy": cell(row, COL_ACCURACY) or None,
                "plusCode": cell(row, COL_LOCATION_TEXT) or None,
                "description": cell(row, COL_DESCRIPTION) or None,
                "photoUrls": photo_urls,
                "categoriesByGroup": categories_by_group,
                "actionTaken": cell(row, COL_ACTION_TAKEN) or None,
            })
            kept += 1

    payload = {
        "source": "Notranjski regijski park — Formidable form export",
        "sourceUrl": "https://nadzor.notranjski-park.si/",
        "exportedAt": date.today().isoformat(),
        "note": "Read-only historical context. Category values kept as free-text, not mapped to the app codebook.",
        "records": records,
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    return {
        "kept": kept,
        "dropped_draft": dropped_draft,
        "dropped_nocategory": dropped_nocategory,
        "dropped_nocoords": dropped_nocoords,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    args = ap.parse_args()
    stats = convert(args.input, args.output)
    print(f"Kept {stats['kept']} records -> {args.output}")
    print(f"Dropped: draft={stats['dropped_draft']}, "
          f"nocategory={stats['dropped_nocategory']}, "
          f"nocoords={stats['dropped_nocoords']}")


if __name__ == "__main__":
    main()
