#!/usr/bin/env python3
"""Characterise the filesystem under a directory: small-file create cost
(1 and N threads), delete cost, and large sequential write throughput.

Usage: fs_microbench.py <label> <dir> [threads]
Prints markdown table rows.
"""
import os
import shutil
import sys
import time
from concurrent.futures import ProcessPoolExecutor

label, base = sys.argv[1], sys.argv[2]
threads = int(sys.argv[3]) if len(sys.argv) > 3 else 8
N_FILES = 20000
FILES_PER_DIR = 500
os.makedirs(base, exist_ok=True)


def create_range(dirpath, start, stop):
  os.makedirs(dirpath, exist_ok=True)
  payload = b'x' * 512
  for i in range(start, stop):
    with open(os.path.join(dirpath, f'f{i}'), 'wb') as f:
      f.write(payload)


def _create(chunk):
  create_range(*chunk)


def create_files(name, workers):
  root = os.path.join(base, name)
  os.makedirs(root)
  chunks = [(os.path.join(root, f'd{i // FILES_PER_DIR}'), i, i + FILES_PER_DIR)
            for i in range(0, N_FILES, FILES_PER_DIR)]
  t = time.time()
  if workers == 1:
    for c in chunks:
      create_range(*c)
  else:
    with ProcessPoolExecutor(max_workers=workers) as ex:
      list(ex.map(_create, chunks))
  secs = time.time() - t
  print(f'| {label}: create {N_FILES} x 512B files, {workers} process(es) | {secs:.1f} s | {N_FILES / secs:.0f} files/s |')
  return root


def delete_tree(name, root):
  t = time.time()
  shutil.rmtree(root)
  secs = time.time() - t
  print(f'| {label}: delete {N_FILES} files ({name}) | {secs:.1f} s | {N_FILES / secs:.0f} files/s |')


if __name__ == '__main__':
  r1 = create_files('single', 1)
  delete_tree('single', r1)
  rN = create_files('multi', threads)
  delete_tree('multi', rN)

  # Large sequential write: 2 GiB in 8 MiB chunks.
  big = os.path.join(base, 'big.bin')
  chunk = b'\0' * (8 * 2**20)
  t = time.time()
  with open(big, 'wb') as f:
    for _ in range(256):
      f.write(chunk)
    f.flush()
    os.fsync(f.fileno())
  secs = time.time() - t
  os.unlink(big)
  print(f'| {label}: sequential write 2 GiB | {secs:.1f} s | {2048 / secs:.0f} MiB/s |')
