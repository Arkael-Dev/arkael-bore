import re, sys
src, dst = sys.argv[1], sys.argv[2]
bad = {"1549", "1618", "1630"}  # hunk show_smap & show_smaps_rollup di task_mmu.c
out, cur, skip, dropped = [], "", False, 0
for line in open(src).read().splitlines(keepends=True):
    if line.startswith("diff --git"):
        cur, skip = line, False
    elif line.startswith("@@ "):
        m = re.match(r"@@ -(\d+),", line)
        skip = "fs/proc/task_mmu.c" in cur and bool(m) and m.group(1) in bad
        if skip:
            dropped += 1
    if not skip:
        out.append(line)
if dropped != 3:
    sys.exit("filter-patch: hunk task_mmu.c yang dibuang = %d, harus 3" % dropped)
open(dst, "w").write("".join(out))
print("filter-patch: 3 hunk task_mmu.c dibuang")
