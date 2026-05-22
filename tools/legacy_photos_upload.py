"""Photo download + upload for the Notranjski legacy import.

Reads tools/legacy_csv_out/TB_MOTNJE_FOTO_urls.csv (the sidecar produced by
legacy_to_tb_motnje_csv.py), fetches each WordPress photo, and uploads it to
TB_MOTNJE_FOTO via the disturbance photo endpoint (ARCHITECTURE.md §9.3).

Prerequisites:
  1. TB_MOTNJE rows already loaded (APEX SQL Workshop or otherwise). The photo
     endpoint 404s when the parent record is missing.
  2. A real narcis_uporabniki account with organizacija = 152 (Notranjski
     regijski park) and TERENSKA-BELEZNICA function authorization. The
     endpoint uses ORG_ID matching on the record, not username matching.
  3. Python stdlib only — no third-party deps.

USTVARJEN_OD caveat (read once, then forget):
  The endpoint stamps TB_MOTNJE_FOTO.USTVARJEN_OD with the *uploader's* email
  on POST — not the synthesized per-photographer email recorded in the URLs
  CSV. The photographer attribution is still preserved at the record level via
  TB_MOTNJE.USTVARJEN_OD. If preserving the photographer email on the photo
  row matters, switch to a direct python-oracledb INSERT approach.

Usage:
  APP_AUTH_EMAIL=alexis.zrimec@gov.si \\
  APP_AUTH_PASSWORD='...' \\
      python3 tools/legacy_photos_upload.py \\
          --input tools/legacy_csv_out/TB_MOTNJE_FOTO_urls.csv \\
          --download-dir tools/legacy_csv_out/photos \\
          --enriched-csv tools/legacy_csv_out/TB_MOTNJE_FOTO.csv

Idempotency:
  - Download step: skips files that already exist locally with non-zero size.
  - Upload step: the ORDS endpoint returns 200 on a duplicate foto_id. A local
    state file (--state) also tracks done foto_ids so re-runs skip the
    upload-side round-trip too.

Failure handling:
  - Per-row failures are logged and counted; the script continues with the next
    row. Re-run to retry only failures (download cache + state file dedupe
    cleanly-completed work).
  - On a 401 from any upload, the script aborts — credentials are bad and
    every subsequent upload will fail the same way.
"""

from __future__ import annotations

import argparse
import base64
import csv
import json
import os
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


ENDPOINT_BASE = "https://narcis.gov.si/ords/narcis/disturbances"
USER_AGENT = "narcis-legacy-import/1.0"
ALLOWED_MIME = {"image/jpeg", "image/png", "image/webp", "image/heic"}
EXT_FOR_MIME = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
    "image/heic": ".heic",
}


def build_auth_header() -> str:
    email = os.environ.get("APP_AUTH_EMAIL")
    password = os.environ.get("APP_AUTH_PASSWORD")
    if not email or not password:
        sys.exit("ERROR: APP_AUTH_EMAIL and APP_AUTH_PASSWORD must be set in the environment.")
    cred = base64.b64encode(f"{email}:{password}".encode("utf-8")).decode("ascii")
    return f"Basic {cred}"


def fetch_url(url: str, timeout: float) -> tuple[bytes, str]:
    req = Request(url, headers={"User-Agent": USER_AGENT})
    with urlopen(req, timeout=timeout) as resp:
        body = resp.read()
        ct_full = resp.headers.get("Content-Type", "") or ""
        mime = ct_full.split(";", 1)[0].strip().lower()
        return body, mime


def normalize_mime(detected: str, fallback: str) -> str:
    if detected in ALLOWED_MIME:
        return detected
    if fallback in ALLOWED_MIME:
        return fallback
    return "image/jpeg"


def upload_photo(motnja_id: str, foto_id: str, body: bytes, mime: str, auth: str, timeout: float) -> int:
    url = f"{ENDPOINT_BASE}/{motnja_id}/photos/{foto_id}"
    req = Request(
        url,
        data=body,
        method="POST",
        headers={
            "X-Narcis-Auth": auth,
            "Content-Type": mime,
            "User-Agent": USER_AGENT,
        },
    )
    with urlopen(req, timeout=timeout) as resp:
        return resp.status


def load_state(path: Path) -> dict:
    if path.exists():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {"done": {}}
    return {"done": {}}


def save_state(state: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2), encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", type=Path, required=True)
    ap.add_argument("--download-dir", type=Path, required=True)
    ap.add_argument("--enriched-csv", type=Path, required=True)
    ap.add_argument(
        "--state",
        type=Path,
        default=Path("tools/legacy_csv_out/photo_upload_state.json"),
    )
    ap.add_argument("--fetch-timeout", type=float, default=30.0)
    ap.add_argument("--upload-timeout", type=float, default=60.0)
    ap.add_argument(
        "--download-only",
        action="store_true",
        help="Skip the ORDS upload step; only refresh the local cache + enriched CSV.",
    )
    args = ap.parse_args()

    auth = "" if args.download_only else build_auth_header()
    args.download_dir.mkdir(parents=True, exist_ok=True)
    state = load_state(args.state)
    done: dict[str, dict] = state.setdefault("done", {})

    rows = list(csv.DictReader(args.input.open(encoding="utf-8")))
    total = len(rows)
    if total == 0:
        sys.exit("ERROR: no rows in input CSV.")

    enriched_fieldnames = [
        "foto_id", "motnja_id", "mime_type", "velikost", "ustvarjen_od",
        "ustvarjen", "local_path", "source_url",
    ]
    enriched = []

    counters = {"downloaded": 0, "download_cached": 0, "uploaded": 0,
                "upload_cached": 0, "fetch_failed": 0, "upload_failed": 0}

    for i, row in enumerate(rows, 1):
        foto_id = row["foto_id"]
        motnja_id = row["motnja_id"]
        url = row["url"]
        mime_hint = row.get("mime_type") or "image/jpeg"
        ext = EXT_FOR_MIME.get(mime_hint, ".jpg")
        local_path = args.download_dir / f"{foto_id}{ext}"

        if local_path.exists() and local_path.stat().st_size > 0:
            counters["download_cached"] += 1
            body = local_path.read_bytes()
            actual_mime = mime_hint  # trust the cached ext-derived hint
        else:
            try:
                body, detected_mime = fetch_url(url, args.fetch_timeout)
                actual_mime = normalize_mime(detected_mime, mime_hint)
                # Rename ext if detected mime disagrees with hint.
                final_ext = EXT_FOR_MIME.get(actual_mime, ".jpg")
                local_path = args.download_dir / f"{foto_id}{final_ext}"
                local_path.write_bytes(body)
                counters["downloaded"] += 1
                print(f"[{i}/{total}] download {foto_id} ok ({len(body)} bytes, {actual_mime})")
            except (HTTPError, URLError, TimeoutError, OSError) as e:
                counters["fetch_failed"] += 1
                print(f"[{i}/{total}] download {foto_id} FAILED: {e!r}")
                enriched.append({
                    "foto_id": foto_id, "motnja_id": motnja_id,
                    "mime_type": "", "velikost": "",
                    "ustvarjen_od": row.get("ustvarjen_od", ""),
                    "ustvarjen": row.get("ustvarjen", ""),
                    "local_path": "", "source_url": url,
                })
                continue

        enriched.append({
            "foto_id": foto_id,
            "motnja_id": motnja_id,
            "mime_type": actual_mime,
            "velikost": len(body),
            "ustvarjen_od": row.get("ustvarjen_od", ""),
            "ustvarjen": row.get("ustvarjen", ""),
            "local_path": str(local_path),
            "source_url": url,
        })

        if args.download_only:
            continue

        if foto_id in done and done[foto_id].get("status") in (200, 201):
            counters["upload_cached"] += 1
            continue

        try:
            status = upload_photo(motnja_id, foto_id, body, actual_mime, auth, args.upload_timeout)
            done[foto_id] = {"status": status, "bytes": len(body), "mime": actual_mime,
                             "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
            counters["uploaded"] += 1
            print(f"[{i}/{total}] upload   {foto_id} -> HTTP {status}")
        except HTTPError as e:
            counters["upload_failed"] += 1
            body_preview = e.read()[:300].decode(errors="replace") if hasattr(e, "read") else ""
            print(f"[{i}/{total}] upload   {foto_id} FAILED: HTTP {e.code} {body_preview!r}")
            if e.code == 401:
                save_state(state, args.state)
                sys.exit("ABORT: auth failed (HTTP 401). Check APP_AUTH_EMAIL/PASSWORD.")
        except (URLError, TimeoutError, OSError) as e:
            counters["upload_failed"] += 1
            print(f"[{i}/{total}] upload   {foto_id} FAILED: {e!r}")

        if i % 20 == 0:
            save_state(state, args.state)

    save_state(state, args.state)

    args.enriched_csv.parent.mkdir(parents=True, exist_ok=True)
    with args.enriched_csv.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=enriched_fieldnames)
        w.writeheader()
        w.writerows(enriched)

    print()
    print("Summary:")
    for k in ("downloaded", "download_cached", "uploaded", "upload_cached",
              "fetch_failed", "upload_failed"):
        print(f"  {k:18s} {counters[k]:5d}")
    print(f"Enriched CSV: {args.enriched_csv}")
    print(f"State file:   {args.state}")


if __name__ == "__main__":
    main()
