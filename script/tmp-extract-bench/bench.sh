#!/bin/bash
# Benchmarks every way of unpacking the src cache on the runner this runs on.
# Works under Git bash on Windows and under bash on Linux (a subset).
#
# env: CACHE_TARBALL  zstd-compressed single tarball (the production cache)
#      SHARDS_DIR     directory of NN.tar.zst shards (plain zstd, no --long)
#      RESULTS        markdown file to append rows to
#      BENCH_ROOT     directory to extract into (inside the workspace)
#      ALT_ROOT       optional second directory outside the workspace
#      SCRIPT_DIR     directory containing count_tree.py etc.
set -u

IS_WIN=0
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WIN=1;; esac
NATIVE_TAR=/c/Windows/System32/tar.exe
SEVENZ=""
if [ "$IS_WIN" = 1 ]; then
  for c in 7z "/c/Program Files/7-Zip/7z.exe" "/c/ProgramData/chocolatey/bin/7z.exe"; do
    if command -v "$c" >/dev/null 2>&1; then SEVENZ="$c"; break; fi
  done
fi
NPROC=$(nproc)
mkdir -p "$BENCH_ROOT"

winpath() { if [ "$IS_WIN" = 1 ]; then cygpath -w "$1"; else echo "$1"; fi; }

row() { echo "| $1 | $2 | $3 | $4 |" | tee -a "$RESULTS"; }

# bench <name> <shell command>   -> records wall seconds + exit code
bench() {
  local name="$1" cmd="$2" s e rc
  echo "::group::$name"
  echo "+ $cmd"
  s=$(date +%s%N)
  bash -o pipefail -c "$cmd" 2> >(tail -n 5 >&2)
  rc=$?
  e=$(date +%s%N)
  LAST_SECS=$(awk "BEGIN{printf \"%.1f\", ($e-$s)/1e9}")
  echo "-> ${LAST_SECS}s rc=$rc"
  echo "::endgroup::"
  LAST_RC=$rc
}

# extract <name> <dest> <command using DEST placeholder>  -> row with file count
extract() {
  local name="$1" dest="$2" cmd="$3" counts
  rm -rf "$dest" 2>/dev/null || true
  mkdir -p "$dest"
  bench "$name" "${cmd//DEST/$dest}"
  local secs=$LAST_SECS rc=$LAST_RC
  counts=$(python3 "$SCRIPT_DIR/count_tree.py" "$dest")
  local files=${counts%% *} rest=${counts#* } walk=${counts##* }
  row "$name" "${secs} s" "rc=$rc, ${files} files (walk ${walk} s)" "$4"
}

# nuke <name> <dir> <how>   -> row with delete time
nuke() {
  local name="$1" dir="$2" how="$3"
  [ -e "$dir" ] || return 0
  case "$how" in
    rmdir) bench "delete: $name (cmd rmdir /s /q)" "MSYS_NO_PATHCONV=1 cmd /c \"rmdir /s /q $(winpath "$dir")\"" ;;
    rm)    bench "delete: $name (msys rm -rf)" "rm -rf \"$dir\"" ;;
    *)     bench "delete: $name (rm -rf)" "rm -rf \"$dir\"" ;;
  esac
  row "delete after '$name' ($how)" "${LAST_SECS} s" "rc=$LAST_RC" ""
  rm -rf "$dir" 2>/dev/null || true
}

echo "| benchmark | wall | result | notes |" | tee -a "$RESULTS"
echo "|---|---|---|---|" | tee -a "$RESULTS"

CACHE_MB=$(( $(stat -c %s "$CACHE_TARBALL") / 1048576 ))
SHARD_MB=$(du -sm "$SHARDS_DIR" | cut -f1)
NSHARDS=$(ls "$SHARDS_DIR"/*.tar.zst | wc -l)
row "inputs" "" "cache ${CACHE_MB} MiB (zstd --long=30), $(ls "$SHARDS_DIR"/*.tar.zst | wc -l) shards ${SHARD_MB} MiB total, ${NPROC} cpus" ""

# ---- 0. costs that don't touch the destination filesystem -------------------
bench "zstd decompress only (to /dev/null)" "zstd -d --long=30 -c \"$CACHE_TARBALL\" > /dev/null"
row "zstd -d --long=30 → /dev/null" "${LAST_SECS} s" "rc=$LAST_RC" "decompression floor; no file creation"

bench "zstd | msys tar -t (list only)" "zstd -d --long=30 -c \"$CACHE_TARBALL\" | tar -tf - | wc -l > \"$BENCH_ROOT/entries.txt\""
row "zstd \| tar -t (parse only)" "${LAST_SECS} s" "$(cat "$BENCH_ROOT/entries.txt") entries" "tar header parsing floor; no file creation"

# ---- 1. single stream extractors --------------------------------------------
D="$BENCH_ROOT/x"
extract "PRODUCTION: zstd \\| msys tar -x" "$D" "zstd -d --long=30 -c \"$CACHE_TARBALL\" | tar -xf - -C \"DEST\"" "what restore-cache-azcopy does today"
if [ "$IS_WIN" = 1 ]; then nuke "msys tar tree" "$D" rm; else nuke "tar tree" "$D" rm; fi

if [ "$IS_WIN" = 1 ] && [ -x "$NATIVE_TAR" ]; then
  extract "zstd \\| native tar.exe (bsdtar) -x" "$D" "zstd -d --long=30 -c \"$CACHE_TARBALL\" | \"$NATIVE_TAR\" -xf - -C \"\$(cygpath -w DEST)\"" "same stream, libarchive instead of msys tar"
  nuke "bsdtar tree" "$D" rmdir
fi

# ---- 2. decompress to disk first, then extract from a plain .tar -------------
FREE_MB=$(df -m "$BENCH_ROOT" | awk 'NR==2{print $4}')
RAW="$BENCH_ROOT/cache.tar"
if [ "$IS_WIN" = 1 ] && [ "$FREE_MB" -gt 70000 ]; then
  bench "zstd -d to a .tar on disk" "zstd -d --long=30 -f -o \"$RAW\" \"$CACHE_TARBALL\""
  row "zstd -d → cache.tar on disk" "${LAST_SECS} s" "rc=$LAST_RC, $(( $(stat -c %s "$RAW") / 1048576 )) MiB" "one-off cost added to the from-disk variants below"
  if [ "$IS_WIN" = 1 ] && [ -x "$NATIVE_TAR" ]; then
    extract "native tar.exe -x from cache.tar (no pipe)" "$D" "\"$NATIVE_TAR\" -xf \"\$(cygpath -w \"$RAW\")\" -C \"\$(cygpath -w DEST)\"" "isolates pipe overhead"
    nuke "bsdtar-from-disk tree" "$D" rmdir
  fi
  if [ -n "$SEVENZ" ]; then
    extract "7z x from cache.tar" "$D" "\"$SEVENZ\" x -y -bso0 -bsp0 -snl \"\$(cygpath -w \"$RAW\")\" -o\"\$(cygpath -w DEST)\"" "7-Zip's tar extractor"
    nuke "7z tree" "$D" rmdir
  else
    row "7z x from cache.tar" "skipped" "7z not on this runner" ""
  fi
  rm -f "$RAW"
elif [ "$IS_WIN" = 1 ]; then
  row "from-disk .tar variants" "skipped" "only ${FREE_MB} MiB free" ""
fi

# ---- 3. sharded parallel extraction ------------------------------------------
shard_cmd() {  # <parallelism> <extractor: native|msys>
  local p="$1" which="$2" x
  if [ "$which" = native ]; then
    x="\"$NATIVE_TAR\" -xf - -C \"\$(cygpath -w DEST)\""
  else
    x="tar -xf - -C \"DEST\""
  fi
  echo "ls \"$SHARDS_DIR\"/*.tar.zst | xargs -P $p -I{} bash -o pipefail -c 'zstd -d -c {} | $x'"
}
if [ "$IS_WIN" = 1 ] && [ -x "$NATIVE_TAR" ]; then
  for p in 1 4 8 16; do
    extract "shards: bsdtar, ${p} parallel" "$D" "$(shard_cmd $p native)" "${NSHARDS} shards, xargs -P ${p}"
    nuke "shards bsdtar P${p} tree" "$D" rmdir
  done
  extract "shards: msys tar, 16 parallel" "$D" "$(shard_cmd 16 msys)" "does msys tar scale too?"
  nuke "shards msys P16 tree" "$D" rmdir
else
  for p in 1 16; do
    extract "shards: tar, ${p} parallel" "$D" "$(shard_cmd $p msys)" "${NSHARDS} shards, xargs -P ${p}"
    nuke "shards P${p} tree" "$D" rm
  done
fi

# ---- 4. same extractor, different location -----------------------------------
if [ "$IS_WIN" = 1 ] && [ -n "${ALT_ROOT:-}" ] && [ -x "$NATIVE_TAR" ]; then
  mkdir -p "$ALT_ROOT"
  A="$ALT_ROOT/x"
  extract "shards: bsdtar, 16 parallel → ALT_ROOT ($(winpath "$ALT_ROOT"))" "$A" "$(shard_cmd 16 native)" "is the workspace path slower than elsewhere on the box?"
  nuke "alt-root tree" "$A" rmdir
fi

# ---- 5. filesystem microbenchmarks -------------------------------------------
echo "" | tee -a "$RESULTS"
echo "| fs microbenchmark | wall | rate | " | tee -a "$RESULTS"
echo "|---|---|---|" | tee -a "$RESULTS"
python3 "$SCRIPT_DIR/fs_microbench.py" "workspace ($(winpath "$BENCH_ROOT"))" "$BENCH_ROOT/micro" 16 | tee -a "$RESULTS"
if [ -n "${ALT_ROOT:-}" ]; then
  python3 "$SCRIPT_DIR/fs_microbench.py" "alt ($(winpath "$ALT_ROOT"))" "$ALT_ROOT/micro" 16 | tee -a "$RESULTS"
fi
