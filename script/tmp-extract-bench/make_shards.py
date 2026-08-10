#!/usr/bin/env python3
"""Split an extracted src cache tree into N roughly file-count-balanced shard
tarballs (src/... entry layout, same as the single cache tarball).

Usage: make_shards.py <dir containing src/> <out dir> <shard count>
"""
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

root, out_dir, n_shards = sys.argv[1], sys.argv[2], int(sys.argv[3])
os.makedirs(out_dir, exist_ok=True)


def count_files(path):
  n = 0
  for _, _, files in os.walk(path):
    n += len(files)
  return n


# Units of work: every entry directly under src/, except third_party (which
# holds ~60% of the files) is split one level further.
units = []  # (file_count, relative path)
src = os.path.join(root, 'src')
for name in sorted(os.listdir(src)):
  rel = os.path.join('src', name)
  full = os.path.join(root, rel)
  if name == 'third_party' and os.path.isdir(full):
    for sub in sorted(os.listdir(full)):
      subrel = os.path.join(rel, sub)
      subfull = os.path.join(root, subrel)
      units.append((count_files(subfull) if os.path.isdir(subfull) else 1, subrel))
  elif os.path.isdir(full) and not os.path.islink(full):
    units.append((count_files(full), rel))
  else:
    units.append((1, rel))

total = sum(c for c, _ in units)
print(f'{len(units)} units, {total} files', flush=True)

# Greedy largest-first assignment to the emptiest bucket.
buckets = [[0, []] for _ in range(n_shards)]
for count, rel in sorted(units, reverse=True):
  b = min(buckets, key=lambda b: b[0])
  b[0] += count
  b[1].append(rel)

for i, (count, _) in enumerate(buckets):
  print(f'shard {i:02d}: {count} files', flush=True)


def build(i):
  count, entries = buckets[i]
  listfile = os.path.join(out_dir, f'{i:02d}.list')
  with open(listfile, 'w') as f:
    f.write('\n'.join(entries) + '\n')
  out = os.path.join(out_dir, f'{i:02d}.tar.zst')
  t = time.time()
  subprocess.check_call(
      f'tar -cf - -C "{root}" -T "{listfile}" | zstd -q -T4 -3 -f -o "{out}"',
      shell=True)
  os.unlink(listfile)
  return i, count, os.path.getsize(out), time.time() - t


t0 = time.time()
with ThreadPoolExecutor(max_workers=8) as ex:
  for i, count, size, secs in ex.map(build, range(n_shards)):
    print(f'shard {i:02d}: {count:8d} files {size / 2**20:7.1f} MiB {secs:5.1f}s',
          flush=True)
print(f'all shards built in {time.time() - t0:.1f}s', flush=True)
