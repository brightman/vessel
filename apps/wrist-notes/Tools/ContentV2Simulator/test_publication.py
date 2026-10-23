#!/usr/bin/env python3
"""Exercise the real publisher against disposable copies of the lab database."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import uuid


def database_digest(path):
    def normalize(value):
        if isinstance(value, bytes):
            try:
                return {"json": json.loads(value)}
            except (ValueError, UnicodeDecodeError):
                return {"blob": value.hex()}
        return value
    with sqlite3.connect(path) as db:
        tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
        state = []
        for table in tables:
            rows = [json.dumps([normalize(v) for v in row],sort_keys=True) for row in db.execute('SELECT * FROM "' + table.replace('"','""') + '"')]
            state.append([table,sorted(rows)])
        return hashlib.sha256(json.dumps(state).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("publisher")
    parser.add_argument("database", type=Path)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("device")
    args = parser.parse_args()
    source = json.loads(args.input.read_text())["sourceID"]
    output = json.loads(args.output.read_text())
    segment_id = str(uuid.UUID(hashlib.sha256(output["segments"][0]["id"].encode()).hexdigest()[:32])).upper()
    failures = []
    cases = ["duplicate_id", "empty_id", "suppression", "tombstone", "manual_edit", "foreign_id", "media_hash", "valid_repeat"]
    for case in cases:
        # Must remain under this simulator's container so the real lab guard applies.
        with tempfile.TemporaryDirectory(prefix="publication-check-", dir=args.database.parent) as folder:
            folder = Path(folder)
            db_path = folder / "daybook.sqlite3"
            with sqlite3.connect(args.database) as original, sqlite3.connect(db_path) as db:
                original.backup(db)
                # Tests require a clean source; never clear the actual lab database.
                db.execute("DELETE FROM content_segments WHERE source_key=?", (source,))
                for table in ("content_segment_tombstones", "content_segment_suppression", "content_segment_edits"):
                    db.execute("DELETE FROM " + table + " WHERE source_key=?", (source,))
                if case == "suppression":
                    db.execute("INSERT INTO content_segment_suppression(source_key,start,end) VALUES (?,1,2)", (source,))
                elif case == "tombstone":
                    db.execute("INSERT INTO content_segment_tombstones(id,source_key,revision) VALUES (?,?,2)", (segment_id,source))
                elif case == "manual_edit":
                    db.execute("INSERT INTO content_segment_edits(source_key,kind,before_payload,after_epoch,undone) VALUES (?,'delete',?,1,0)", (source,b"[]"))
                elif case == "foreign_id":
                    fields = [r[1] for r in db.execute("PRAGMA table_info(audio_processing_sources)")]
                    row = list(db.execute("SELECT * FROM audio_processing_sources WHERE source_key=?", (source,)).fetchone())
                    row[fields.index("source_key")] = "legacyNote:00000000-0000-0000-0000-000000000001"
                    db.execute("INSERT INTO audio_processing_sources(" + ",".join(fields) + ") VALUES (" + ",".join("?" for _ in fields) + ")", row)
                    db.execute("INSERT INTO content_segments(id,source_key,start,revision,deleted,payload) VALUES (?,?,0,1,0,?)", (segment_id,row[fields.index("source_key")],b"{}"))
                elif case == "media_hash":
                    descriptor = json.loads(db.execute("SELECT descriptor FROM audio_processing_sources WHERE source_key=?", (source,)).fetchone()[0])
                    descriptor["ranges"][0]["contentHash"] = "0" * 64
                    db.execute("UPDATE audio_processing_sources SET descriptor=? WHERE source_key=?", (json.dumps(descriptor).encode(),source))
                db.commit()
            mutated = copy.deepcopy(output)
            if case == "duplicate_id":
                mutated["segments"][1]["id"] = mutated["segments"][0]["id"]
            elif case == "empty_id":
                mutated["segments"][0]["id"] = " "
            result_path = folder / "output.json"
            result_path.write_text(json.dumps(mutated))
            before = database_digest(db_path)
            command = [args.publisher,str(db_path),str(args.input),str(result_path),"Doubao-Seed-2.0-mini",args.device]
            result = subprocess.run(command, capture_output=True, text=True)
            if case == "valid_repeat":
                with sqlite3.connect(db_path) as db:
                    count = db.execute("SELECT count(*) FROM content_segments WHERE source_key=? AND deleted=0", (source,)).fetchone()[0]
                first = database_digest(db_path)
                repeat = subprocess.run(command,capture_output=True,text=True)
                passed = result.returncode == 0 and repeat.returncode == 0 and count == len(output["segments"]) and database_digest(db_path) == first
            else:
                passed = result.returncode != 0 and database_digest(db_path) == before
            print(("PASS " if passed else "FAIL ") + case, flush=True)
            if not passed:
                failures.append(case)
                print("  exit:", result.returncode, "database_unchanged:", database_digest(db_path) == before)
                print("  " + (result.stdout + result.stderr)[:400].replace("\n", " "))
                if case == "valid_repeat":
                    print("  count:", count, "repeat_exit:", repeat.returncode, "repeat_unchanged:", database_digest(db_path) == first)
    if failures:
        raise SystemExit("Publication regressions: " + ", ".join(failures))
    print("8 publication checks passed")


if __name__ == "__main__":
    main()
