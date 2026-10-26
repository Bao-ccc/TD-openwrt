#!/usr/bin/env python3
"""
pack.py —— 打包成 zip，**完整保留符号链接**

为什么要单独写：
  Python `zipfile` + `os.walk` 的默认组合会把「指向目录的符号链接」弄丢。
  `os.walk` 用 `entry.is_dir()` 判类型，而 `is_dir()` **会跟随符号链接**，
  于是 `po/zh_Hans -> zh-cn` 被归进 dirnames；又因为 `followlinks=False` 不递归，
  **整个条目就被静默丢掉了**。上游 LuCI 包普遍用 `zh_Hans`/`zh_Hant` 这种
  符号链接做语言目录兼容，丢了会导致本地编译找不到语言文件。

用法:
    python3 tools/pack.py [源目录=github-release-sync] [输出=github-release-sync.zip]

zip 里符号链接的表示：
    external_attr = 0o120777 << 16（S_IFLNK | 0777）
    create_system = 3            （Unix）
    文件内容 = 链接目标字符串
  这是 unzip / 7z / macOS 归档工具都认的标准做法，解压时会还原成真正的符号链接。
"""
import os
import sys
import zipfile

S_IFLNK = 0o120000


def add_symlink(z, arcname, target):
    info = zipfile.ZipInfo(arcname)
    info.external_attr = (S_IFLNK | 0o777) << 16
    info.create_system = 3  # Unix
    z.writestr(info, target)


def add_file(z, path, arcname):
    st = os.lstat(path)
    info = zipfile.ZipInfo.from_file(path, arcname)
    info.external_attr = (st.st_mode & 0xFFFF) << 16
    info.create_system = 3
    with open(path, "rb") as f:
        z.writestr(info, f.read(), zipfile.ZIP_DEFLATED)


def pack(root, out, skip=(".state", ".git", "__pycache__")):
    n_link = n_file = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for dp, dns, fns in os.walk(root, followlinks=False):
            dns[:] = sorted(d for d in dns if d not in skip)

            # 目录里的符号链接（可能指向目录！）—— os.walk 会把它们混进 dirnames
            for d in list(dns):
                p = os.path.join(dp, d)
                if os.path.islink(p):
                    add_symlink(z, p.replace(os.sep, "/"), os.readlink(p))
                    dns.remove(d)  # 不再深入
                    n_link += 1

            for fn in sorted(fns):
                if fn in skip:
                    continue
                p = os.path.join(dp, fn)
                arc = p.replace(os.sep, "/")
                if os.path.islink(p):
                    add_symlink(z, arc, os.readlink(p))
                    n_link += 1
                else:
                    add_file(z, p, arc)
                    n_file += 1
    return n_file, n_link


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "github-release-sync"
    out = sys.argv[2] if len(sys.argv) > 2 else "github-release-sync.zip"
    if os.path.exists(out):
        os.remove(out)
    nf, nl = pack(root, out)
    print(f"打包完成: {out}  普通文件 {nf}  符号链接 {nl}")
    if nl:
        with zipfile.ZipFile(out) as z:
            for i in z.infolist():
                if (i.external_attr >> 16) & 0o170000 == S_IFLNK:
                    print(f"  link {i.filename} -> {z.read(i.filename).decode()}")


if __name__ == "__main__":
    main()
