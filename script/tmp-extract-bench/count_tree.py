#!/usr/bin/env python3
"""Print '<files> <dirs> <walk_seconds>' for a tree (also a stat()-walk timing)."""
import os
import sys
import time

t = time.time()
files = dirs = 0
for _, d, f in os.walk(sys.argv[1]):
  dirs += len(d)
  files += len(f)
print(f'{files} {dirs} {time.time() - t:.1f}')
