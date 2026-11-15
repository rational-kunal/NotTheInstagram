import argparse
import json
import mmap
import re
import struct
import sys


class ObjCMetadata:
    """Read Objective-C metadata from the extracted ARM64 Instagram binary."""

    def __init__(self, data):
        self.data = data
        self.segments = []
        self.class_lists = []
        offset = 32
        for _ in range(self.uint32(16)):
            command, size = struct.unpack_from("<II", data, offset)
            if command == 0x19:  # LC_SEGMENT_64
                address, _, file_offset, file_size = struct.unpack_from("<QQQQ", data, offset + 24)
                self.segments.append((address, file_offset, file_size))
                for index in range(self.uint32(offset + 64)):
                    section = offset + 72 + 80 * index
                    name = data[section:section + 16].rstrip(b"\0")
                    if name == b"__objc_classlist":
                        size_bytes = struct.unpack_from("<Q", data, section + 40)[0]
                        self.class_lists.append((self.uint32(section + 48), size_bytes))
            offset += size

    def uint32(self, offset):
        return struct.unpack_from("<I", self.data, offset)[0]

    def pointer(self, offset):
        return struct.unpack_from("<Q", self.data, offset)[0] & 0xFFFFFFFFF

    def offset(self, address):
        for start, offset, size in self.segments:
            if start <= address < start + size:
                return offset + address - start
        raise ValueError(hex(address))

    def string(self, address):
        offset = self.offset(address)
        end = self.data.find(b"\0", offset)
        return self.data[offset:end].decode(errors="replace")

    def class_data_offset(self, address):
        return self.offset(self.pointer(self.offset(address) + 32) & ~7)

    def methods(self, address):
        if not address:
            return []
        offset = self.offset(address)
        flags, count = struct.unpack_from("<II", self.data, offset)
        stride = flags & 0xFFFF
        relative = flags & 0x80000000
        direct = flags & 0x40000000
        result = []
        for index in range(count):
            entry = offset + 8 + index * stride
            if relative:
                entry_address = address + 8 + index * stride
                name_delta, types_delta, imp_delta = struct.unpack_from("<iii", self.data, entry)
                name = entry_address + name_delta
                if not direct:
                    name = self.pointer(self.offset(name))
                types = entry_address + 4 + types_delta
                imp = entry_address + 8 + imp_delta
            else:
                name, types, imp = (self.pointer(entry + field) for field in (0, 8, 16))
            result.append({"selector": self.string(name), "types": self.string(types), "imp": hex(imp)})
        return result

    def classes_matching(self, pattern):
        for offset, size in self.class_lists:
            for entry in range(offset, offset + size, 8):
                try:
                    address = self.pointer(entry)
                    data = self.class_data_offset(address)
                    name = self.string(self.pointer(data + 24))
                    if not pattern.search(name):
                        continue
                    header = self.offset(address)
                    result = {
                        "class": name,
                        "address": hex(address),
                        "super_address": hex(self.pointer(header + 8)),
                        "methods": self.methods(self.pointer(data + 32)),
                    }
                except (ValueError, struct.error):
                    continue
                try:
                    metaclass_data = self.class_data_offset(self.pointer(header))
                    result["class_methods"] = self.methods(self.pointer(metaclass_data + 32))
                except (ValueError, struct.error) as error:
                    result["class_methods_error"] = str(error)
                yield result


def dump_classes(pattern):
    parser = argparse.ArgumentParser(description="Extract Objective-C classes from the Instagram ARM64 executable.")
    parser.add_argument("path")
    args = parser.parse_args()
    with open(args.path, "rb") as binary, mmap.mmap(binary.fileno(), 0, access=mmap.ACCESS_READ) as data:
        classes = list(ObjCMetadata(data).classes_matching(re.compile(pattern)))
    json.dump({
        "path": args.path,
        "source": "original Mach-O Objective-C class_ro_t and method_list_t metadata; no target execution",
        "classes": classes,
    }, sys.stdout, indent=2)
