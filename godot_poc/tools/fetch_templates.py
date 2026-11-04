# -*- coding: utf-8 -*-
"""只从 Godot 的 export_templates.tpz 里取需要的模板，不全量下载。

背景：官方模板包 1.28 GB（全平台），而本项目只需要 Windows 的
release 模板（解压后约 104 MB）。tpz 就是普通 zip，zip 的中央目录
在文件末尾，所以：

  1) Range 取末尾 64 KB → 解析 EOCD → 拿到所有条目的偏移/大小；
  2) 对需要的条目再发 Range，只下那一段，解压写盘。

为什么用 curl 而不是 urllib：本机这条链路上的代理会把 urllib 的
HTTP/1.1 长连接掐在半路（实测跑十分钟一个字节都不落盘），而 curl
加 --ssl-no-revoke 能稳定拿到 206。curl 也顺便解决了 Windows 上
证书吊销列表检查失败（CRYPT_E_NO_REVOCATION_CHECK）的问题。

用法：
    python tools/fetch_templates.py                 # 取 windows 模板
    python tools/fetch_templates.py --list          # 只列条目，不下载
    python tools/fetch_templates.py --release-only  # 只取 release（省一半流量）

装好之后 Godot 的「导出」就能用了；目录是
    %APPDATA%/Godot/export_templates/<version>/
"""
import argparse
import os
import subprocess
import sys
import tempfile
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_VER = "4.7.2"
TPZ = ("https://github.com/godotengine/godot/releases/download/"
       "{v}-stable/Godot_v{v}-stable_export_templates.tpz")

# 需要从包里捞出来的文件（按平台）
WANT = {
    "windows": [
        "windows_debug_x86_64.exe",
        "windows_release_x86_64.exe",
        "windows_debug_x86_64_console.exe",
        "windows_release_x86_64_console.exe",
    ],
}

CURL_BASE = ["curl", "-sS", "-L", "--ssl-no-revoke", "--retry", "2",
             "--retry-delay", "2", "--connect-timeout", "30"]


def curl_bytes(url, start, end, timeout=180):
    """取一段字节到内存。用于读 zip 中央目录这类小请求。"""
    cmd = CURL_BASE + ["-r", "%d-%d" % (start, end), "--max-time", str(timeout), url]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if not p.stdout and p.returncode != 0:
        raise IOError(p.stderr.decode("utf-8", "replace").strip()[:200])
    return p.stdout


def remote_size(url):
    """拿远端总长度。

    这个 release 资产会被 302 到 Azure Blob，Range 请求虽然返回 206，
    但**不带 Content-Range**，所以只能看 Content-Length。
    curl -I 会跟随重定向拿到最终的 Content-Length。
    """
    cmd = CURL_BASE + ["-I", "--max-time", "60", url]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    size = 0
    for line in p.stdout.decode("latin-1").splitlines():
        if line.lower().startswith("content-length:"):
            size = int(line.split(":", 1)[1].strip())   # 重定向链有多条，取最后一条
    if not size:
        raise RuntimeError("拿不到远端大小")
    return size


class HttpFile(object):
    """把远端文件包成可 seek 的只读文件，专供 zipfile 读中央目录。

    只实现 zipfile 需要的那点接口：read/seek/tell/seekable。
    每次 read 都是一次 Range 请求，所以调用方要尽量一次读一大块。
    """

    def __init__(self, url, size):
        self.url = url
        self.size = size
        self.pos = 0

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, off, whence=0):
        if whence == 0:
            self.pos = off
        elif whence == 1:
            self.pos += off
        elif whence == 2:
            self.pos = self.size + off
        self.pos = max(0, min(self.pos, self.size))
        return self.pos

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        if n == 0 or self.pos >= self.size:
            return b""
        end = min(self.pos + n, self.size) - 1
        data = curl_bytes(self.url, self.pos, end)
        self.pos += len(data)
        return data


def fetch_entry(url, zf, name, out_path, chunk=2 << 20, rounds=400):
    """分块 Range 下载 + 落盘，可续传。

    为什么不是「一次 Range 抓完整条」：这条链路单请求传几百 KB 就会断。
    所以拆成小块，每块独立重试；已经写下的字节不重下。
    关键点：curl 直接把 body 写进 .part 的文件句柄，**断掉时已写下的
    那部分仍然有效**，下一轮从新的文件长度继续，无需事务。
    """
    info = zf.getinfo(name)
    start = info.header_offset
    head = curl_bytes(url, start, start + 30 + 1024)
    if head[:4] != b"PK\x03\x04":
        raise RuntimeError("本地文件头签名不对：%r" % head[:4])
    nlen = int.from_bytes(head[26:28], "little")
    elen = int.from_bytes(head[28:30], "little")
    data_start = start + 30 + nlen + elen
    total = info.compress_size

    part = out_path + ".part"
    done = os.path.getsize(part) if os.path.exists(part) else 0
    if done > total:
        log("  .part 比预期长（%d > %d），重下" % (done, total))
        os.remove(part)
        done = 0

    stall = 0
    with open(part, "ab") as out:
        while done < total:
            end = min(done + chunk, total) - 1
            cmd = CURL_BASE + ["-r", "%d-%d" % (data_start + done, data_start + end),
                               "--max-time", "240", url]
            before = out.tell()
            p = subprocess.run(cmd, stdout=out, stderr=subprocess.PIPE)
            out.flush()
            got = out.tell() - before
            if got <= 0:
                stall += 1
                if stall >= 6:
                    raise IOError("连续 %d 次没拿到数据（%s）"
                                  % (stall, p.stderr.decode("utf-8", "replace").strip()[:160]))
                time.sleep(2 + stall * 2)
                continue
            if got < end - done + 1:
                # 半截也算数：Range 响应是顺序前缀，写下的部分就是正确数据
                stall = 0
            else:
                stall = 0
            done += got
            log("    %-34s %5.1f%%  %s / %s"
                % (name.rsplit("/", 1)[-1], 100.0 * done / total, fmt(done), fmt(total)))

    # 解压校验：压缩流必须正好用完，且长度对得上
    with open(part, "rb") as f:
        raw = f.read()
    if info.compress_type == 0:
        data = raw
    elif info.compress_type == 8:
        import zlib
        data = zlib.decompress(raw, -15)
    else:
        raise RuntimeError("不支持的压缩方式 %d" % info.compress_type)
    if len(data) != info.file_size:
        raise RuntimeError("解压长度不对：%d != %d" % (len(data), info.file_size))

    with open(out_path, "wb") as f:
        f.write(data)
    os.remove(part)


def log(msg):
    print(msg, flush=True)
    try:
        with open(os.path.join(HERE, ".fetch_progress.log"), "a", encoding="utf-8") as f:
            f.write(msg + "\n")
    except OSError:
        pass


def fmt(n):
    return "%.1f MB" % (n / 1048576.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default=DEFAULT_VER)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--platform", default="windows", choices=sorted(WANT))
    ap.add_argument("--release-only", action="store_true",
                    help="只取 release 模板（发行只需要它，省一半流量）")
    a = ap.parse_args()

    url = TPZ.format(v=a.version)
    size = remote_size(url)
    log("远端 %s  %s" % (url.rsplit("/", 1)[-1], fmt(size)))

    # 代理偶尔会把一次 Range 响应截断，zipfile 读中央目录就会报 "not a zip file"。
    # 换一个连接重试即可，不必重下 1.28 GB。
    zf = None
    for attempt in range(5):
        try:
            zf = zipfile.ZipFile(HttpFile(url, size))
            break
        except zipfile.BadZipFile:
            log("  中央目录读取失败，重试 %d" % (attempt + 1))
            time.sleep(1)
    if zf is None:
        print("读不到 zip 中央目录（网络问题），请重跑")
        return 1
    names = zf.namelist()

    if a.list:
        for n in names:
            if a.platform in n:
                print("  %-46s %s" % (n, fmt(zf.getinfo(n).file_size)))
        return 0

    # Godot 找模板的目录名是 VERSION_FULL_CONFIG（"4.7.2.stable"），
    # 而下载 URL 里只有 "4.7.2"。两者差一个后缀，写错目录会让编辑器"看不见"模板。
    dirname = a.version if a.version.endswith(".stable") else a.version + ".stable"
    dest = os.path.join(os.environ["APPDATA"], "Godot", "export_templates", dirname)
    os.makedirs(dest, exist_ok=True)

    got = 0
    wanted = WANT[a.platform]
    if a.release_only:
        wanted = [w for w in wanted if "_release_" in w]
    for want in wanted:
        hit = [n for n in names if n.endswith("/" + want) or n == want]
        if not hit:
            print("  跳过（包里没有）%s" % want)
            continue
        target = os.path.join(dest, want)
        if os.path.exists(target) and os.path.getsize(target) == zf.getinfo(hit[0]).file_size:
            log("  已存在，跳过 %-34s %s" % (want, fmt(os.path.getsize(target))))
            got += 1
            continue
        info = zf.getinfo(hit[0])
        log("  取 %-40s %s → %s" % (want, fmt(info.file_size), fmt(info.compress_size)))
        fetch_entry(url, zf, hit[0], target)
        got += 1

    # Godot 用 version.txt 里的版本号判断模板是否匹配当前编辑器
    with open(os.path.join(dest, "version.txt"), "w", encoding="utf-8", newline="\n") as out:
        out.write(a.version + "\n")

    print("装好 %d 个文件 -> %s" % (got, dest))
    for n in sorted(os.listdir(dest)):
        p = os.path.join(dest, n)
        if os.path.isfile(p):
            print("   ", n, fmt(os.path.getsize(p)))
    return 0 if got else 1


if __name__ == "__main__":
    sys.exit(main())
