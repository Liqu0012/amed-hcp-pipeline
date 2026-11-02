#!/usr/bin/env python3
"""Finish an atomic image transfer, verify its checksum, then release a held canary.

Run as the image owner. Never overwrite an existing final image with different
content. The caller supplies the expected checksum from the source platform.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('image'); p.add_argument('sha256'); p.add_argument('bytes', type=int)
p.add_argument('--release-job'); p.add_argument('--timeout-hours', type=float, default=48)
a = p.parse_args(); image = pathlib.Path(a.image); part = pathlib.Path(str(image) + '.part')
deadline = time.time() + a.timeout_hours * 3600
while not image.exists():
    if time.time() > deadline:
        raise SystemExit('Image transfer timed out; canary remains held')
    if part.exists() and part.stat().st_size == a.bytes:
        break
    time.sleep(30)
candidate = image if image.exists() else part
h = hashlib.sha256()
with candidate.open('rb') as stream:
    for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
        h.update(block)
if candidate.stat().st_size != a.bytes or h.hexdigest() != a.sha256:
    raise SystemExit('Image checksum mismatch; canary remains held')
if candidate == part:
    part.rename(image)
ready = {'image': str(image), 'sha256': h.hexdigest(), 'bytes': a.bytes,
         'validated_at_epoch': time.time(), 'source': 'kytk/l4n-bmb:latest'}
pathlib.Path(str(image) + '.ready.json').write_text(json.dumps(ready, indent=2))
if a.release_job:
    subprocess.check_call(['scontrol', 'release', a.release_job])
print(json.dumps(ready))
