#!/usr/bin/env python3
"""
inject.py — tiêm 1 hoặc nhiều dylib vào .app (đã giải nén từ IPA) và thêm
LC_LOAD_DYLIB @rpath/<name> vào Mach-O chính. Không cần optool.

Yêu cầu: pip install lief      (macOS/Linux/Windows đều được)

Dùng:
  python3 inject.py Payload/Locket.app LocketPlus.dylib
  python3 inject.py --ipa Locket.ipa out.ipa LocketPlus.dylib
"""
import os
import shutil
import sys
import zipfile

try:
    import lief
except ImportError:
    sys.exit("Thiếu lief: pip install lief")


def inject_into_app(app_dir: str, dylibs):
    exe_name = os.path.basename(app_dir)[:-4] if app_dir.endswith(".app") else None
    if not exe_name:
        sys.exit("Tham số phải là đường dẫn tới X.app")
    exe = os.path.join(app_dir, exe_name)
    if not os.path.isfile(exe):
        sys.exit(f"Không thấy executable: {exe}")

    bin_ = lief.parse(exe)
    fw_dir = os.path.join(app_dir, "Frameworks")
    os.makedirs(fw_dir, exist_ok=True)

    for lib in dylibs:
        dst = os.path.join(fw_dir, os.path.basename(lib))
        shutil.copy2(lib, dst)
        os.chmod(dst, 0o755)
        path = "@rpath/" + os.path.basename(lib)
        if any(path in c.name for c in bin_.commands if hasattr(c, "name") and c.name == path):
            print(f"[=] đã có load command cho {path}")
            continue
        cmd = lief.MachO.DylibCommand.library(path)
        bin_.add(cmd)
        print(f"[+] thêm LC_LOAD_DYLIB {path}")

    # Bỏ code signature cũ của main binary (bản mod sẽ được ký lại khi sideload)
    for c in list(bin_.commands):
        if getattr(c, "command", None) == lief.MachO.LoadCommand.TYPE.CODE_SIGNATURE:
            bin_.remove(c)
            print("[+] bỏ LC_CODE_SIGNATURE")

    out = exe + ".patched"
    bin_.write(out)
    os.replace(out, exe)
    os.chmod(exe, 0o755)
    print(f"[✓] đã vá {exe}")

    # Xoá _CodeSignature của app — tool sideload sẽ ký lại
    sig = os.path.join(app_dir, "_CodeSignature")
    if os.path.isdir(sig):
        shutil.rmtree(sig, ignore_errors=True)
        print("[+] xoá _CodeSignature/")


def inject_ipa(ipa_in: str, ipa_out: str, dylibs):
    work = "/tmp/lp_inject"
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    with zipfile.ZipFile(ipa_in) as z:
        z.extractall(work)
    apps = [os.path.join(work, "Payload", d) for d in os.listdir(os.path.join(work, "Payload"))
            if d.endswith(".app")]
    if not apps:
        sys.exit("IPA không có Payload/*.app")
    inject_into_app(apps[0], dylibs)
    with zipfile.ZipFile(ipa_out, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(work):
            for f in files:
                full = os.path.join(root, f)
                z.write(full, os.path.relpath(full, work))
    print(f"[✓] IPA: {ipa_out}")


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    if args[0] == "--ipa":
        inject_ipa(args[1], args[2], args[3:])
    else:
        inject_into_app(args[0], args[1:])
