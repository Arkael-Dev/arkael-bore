import re, sys
p = sys.argv[1]
s = open(p).read()
if "SUSFS_FIX_SMAP" in s:
    sys.exit(0)

# 1) show_smap
reA = re.compile(r"(static int show_smap\(struct seq_file \*m, void \*v\)\n\{\n[ \t]*struct vm_area_struct \*vma = v;\n[ \t]*struct mem_size_stats mss = \{\};\n)")
if not reA.search(s):
    sys.exit("fix-task-mmu: anchor show_smap tidak ketemu")
blk = ("\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
       "\t/* SUSFS_FIX_SMAP */\n"
       "\tif (vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n"
       "\t\treturn 0;\n"
       "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n")
s = reA.sub(lambda m: m.group(1) + blk, s, count=1)

# 2) show_smaps_rollup: lewati vma sus_map saat gather stats
a = s.index("static int show_smaps_rollup")
b = s.index("empty_set:", a)
seg = s[a:b]
reB = re.compile(r"^([ \t]*)(smap_gather_stats\(vma, &mss, [^;]*\);)$", re.M)
seg, n = reB.subn(lambda m: "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n" + m.group(1)
    + "if (!(vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file))))\n#endif\n"
    + m.group(1) + m.group(2), seg)
if n != 3:
    sys.exit("fix-task-mmu: smap_gather_stats di rollup = %d, harus 3" % n)
s = s[:a] + seg + s[b:]
open(p, "w").write(s)
print("fix-task-mmu: show_smap & show_smaps_rollup terpasang")
