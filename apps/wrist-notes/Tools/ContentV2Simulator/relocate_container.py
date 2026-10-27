#!/usr/bin/env python3
"""Refresh only this lab fixture's file references after simctl reinstalls the app."""
import json
import plistlib
from pathlib import Path
import sqlite3
import subprocess
import sys


def main():
    root = Path(sys.argv[1]).resolve()
    manifest_path = root / "import-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    device = manifest["device"]
    device_root = Path.home() / "Library/Developer/CoreSimulator/Devices" / device
    with (device_root / "device.plist").open("rb") as file:
        info = plistlib.load(file)
    assert info["name"] == "WiseLife Content Lab" and info["UDID"] == device
    current = subprocess.check_output(["xcrun", "simctl", "get_app_container", device, "cloud.karama.wisenote", "data"],text=True).strip()
    assert current.startswith(str(device_root / "data/Containers/Data/Application") + "/")
    old = manifest["container"]
    if old == current:
        print("Container references already current")
        return
    assert old.startswith(str(device_root / "data/Containers/Data/Application") + "/")
    assert Path(manifest["audio"].replace(old,current)).is_file()

    def replace(value):
        if isinstance(value,str): return value.replace(old,current)
        if isinstance(value,list): return [replace(item) for item in value]
        if isinstance(value,dict): return {key:replace(item) for key,item in value.items()}
        return value

    backup = root / ("before-relocation-" + Path(current).name + ".sqlite3")
    assert not backup.exists(), "Refusing to replace backup"
    with sqlite3.connect(manifest["database"].replace(old,current)) as db:
        with sqlite3.connect(backup) as destination: db.backup(destination)
        for table, column in [("audio_processing_sources","descriptor"),("audio_processing_jobs","window"),("content_segments","payload"),("content_segment_ranges","payload")]:
            predicate = "segment_id IN (SELECT id FROM content_segments WHERE source_key=?)" if table == "content_segment_ranges" else "source_key=?"
            rows = db.execute("SELECT rowid," + column + " FROM " + table + " WHERE " + predicate,(manifest["sourceID"],)).fetchall()
            for rowid,payload in rows:
                original=json.loads(payload); updated=replace(original)
                if original != updated:
                    db.execute("UPDATE " + table + " SET " + column + "=? WHERE rowid=?",(json.dumps(updated,ensure_ascii=False).encode(),rowid))
        db.commit()
    for key in ("container","database","audio"): manifest[key]=manifest[key].replace(old,current)
    manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
    print("Relocated source, window and segment media paths; source identity and content unchanged")


if __name__ == "__main__":
    main()
