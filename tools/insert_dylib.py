#!/usr/bin/env python3
"""
Tiêm một LC_LOAD_DYLIB vào Mach-O mà KHÔNG dịch chuyển byte nào.

Vì sao không chèn byte: load command nằm ở đầu __TEXT, ngay trước section đầu
tiên. Chèn byte vào đó làm mọi offset trong file (segment fileoff, symtab,
section offset) lệch đi → dyld đọc rác → app chết ngay khi mở.

Cách đúng: ghi load command vào phần ĐỆM có sẵn giữa cuối load command và
section đầu tiên (mọi binary của Apple/Xcode đều có đệm này, thường ≥ 1KB).
Nếu không đủ chỗ thì báo lỗi rõ ràng thay vì làm hỏng file.

Dùng: python3 insert_dylib.py <macho> <@executable_path/.../Foo.dylib>
"""
import struct
import sys

LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
LC_CODE_SIGNATURE = 0x1D
MH_MAGIC_64 = 0xFEEDFACF


def walk(data, ncmds):
    """Trả về list (offset, cmd, size). Dừng an toàn nếu size == 0."""
    out = []
    i = 32
    for _ in range(ncmds):
        if i + 8 > len(data):
            break
        cmd, size = struct.unpack_from("<II", data, i)
        if size < 8:
            break
        out.append((i, cmd, size))
        i += size
    return out


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2

    path, dylib = sys.argv[1], sys.argv[2]
    data = bytearray(open(path, "rb").read())

    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, _ = \
        struct.unpack_from("<IiiIIIII", data, 0)
    if magic != MH_MAGIC_64:
        print("lỗi: không phải Mach-O 64-bit (magic 0x%08x)" % magic)
        return 1

    cmds = walk(data, ncmds)
    if len(cmds) != ncmds:
        print("lỗi: chuỗi load command hỏng (%d/%d đọc được)" % (len(cmds), ncmds))
        return 1

    lc_end = 32 + sizeofcmds

    # Đã tiêm rồi?
    for (off, cmd, size) in cmds:
        if cmd != LC_LOAD_DYLIB:
            continue
        name_off = struct.unpack_from("<I", data, off + 8)[0]
        end = data.index(b"\0", off + name_off)
        if data[off + name_off:end].decode("utf-8", "replace") == dylib:
            print("đã có %s — bỏ qua" % dylib)
            return 0

    # File offset nhỏ nhất của section trong __TEXT (mốc hết vùng đệm).
    first_section = None
    for (off, cmd, size) in cmds:
        if cmd != LC_SEGMENT_64:
            continue
        segname = data[off + 8:off + 24].rstrip(b"\0").decode()
        if segname != "__TEXT":
            continue
        nsects = struct.unpack_from("<I", data, off + 64)[0]
        p = off + 72
        for _ in range(nsects):
            fileoff = struct.unpack_from("<I", data, p + 48)[0]
            if fileoff > 0 and (first_section is None or fileoff < first_section):
                first_section = fileoff
            p += 80

    if first_section is None:
        print("lỗi: không xác định được vùng đệm sau load command")
        return 1

    name = dylib.encode() + b"\0"
    pad = (8 - (len(name) % 8)) % 8
    cmd_size = 24 + len(name) + pad

    room = first_section - lc_end
    if cmd_size > room:
        print("lỗi: chỉ còn %d byte đệm, cần %d. Dùng insert_dylib/optool."
              % (room, cmd_size))
        return 1

    cmd = struct.pack("<IIIIII", LC_LOAD_DYLIB, cmd_size, 24, 0, 0, 0)
    cmd += name + b"\0" * pad
    data[lc_end:lc_end + cmd_size] = cmd

    struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + cmd_size)

    # Code signature cũ giờ sai. KHÔNG xoá command (xoá là đứt chuỗi load
    # command → dyld từ chối file). Chỉ đặt dataoff/datasize = 0 để công cụ ký
    # (ldid/codesign/Sideloadly) ghi blob mới vào.
    for (off, cmd_id, size) in cmds:
        if cmd_id == LC_CODE_SIGNATURE:
            struct.pack_into("<II", data, off + 8, 0, 0)
            print("đã vô hiệu hoá LC_CODE_SIGNATURE cũ (sẽ ký lại)")
            break

    open(path, "wb").write(data)
    print("đã thêm LC_LOAD_DYLIB %s (%d byte, còn %d byte đệm)"
          % (dylib, cmd_size, room - cmd_size))
    return 0


if __name__ == "__main__":
    sys.exit(main())
