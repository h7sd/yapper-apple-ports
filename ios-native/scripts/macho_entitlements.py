"""Read embedded Simulator entitlements from owned Mach-O artifacts without executing them."""

from pathlib import Path
import plistlib
import struct


_ARCHITECTURES = {0x0100000C: "arm64", 0x01000007: "x86_64"}


def _range(data: bytes, offset: int, size: int) -> bytes:
    if offset < 0 or size < 0 or offset > len(data) or size > len(data) - offset:
        raise ValueError("Mach-O range exceeds its architecture slice")
    return data[offset : offset + size]


def _thin_entitlements(data: bytes, expected_cpu: int | None = None) -> tuple[str, dict]:
    magic = _range(data, 0, 4)
    if magic == b"\xcf\xfa\xed\xfe":
        endian = "<"
    elif magic == b"\xfe\xed\xfa\xcf":
        endian = ">"
    else:
        raise ValueError("Unsupported Mach-O architecture magic")
    header = struct.unpack(endian + "8I", _range(data, 0, 32))
    cpu, command_count, command_bytes = header[1], header[4], header[5]
    if cpu not in _ARCHITECTURES or (expected_cpu is not None and cpu != expected_cpu):
        raise ValueError("Unsupported or mismatched Mach-O architecture")
    _range(data, 32, command_bytes)
    command_end = 32 + command_bytes
    if command_count > command_bytes // 8:
        raise ValueError("Invalid Mach-O load command count")
    offset = 32
    result = None
    for _ in range(command_count):
        if offset + 8 > command_end:
            raise ValueError("Truncated Mach-O load command")
        command, size = struct.unpack(endian + "2I", _range(data, offset, 8))
        if size < 8 or size > command_end - offset:
            raise ValueError("Invalid Mach-O load command size")
        if command == 0x19:  # LC_SEGMENT_64
            if size < 72:
                raise ValueError("Truncated Mach-O segment")
            segment = _range(data, offset + 8, 16).rstrip(b"\0")
            sections = struct.unpack(endian + "I", _range(data, offset + 64, 4))[0]
            if sections > (size - 72) // 80:
                raise ValueError("Invalid Mach-O section count")
            for index in range(sections):
                section = offset + 72 + index * 80
                name = _range(data, section, 16).rstrip(b"\0")
                owner = _range(data, section + 16, 16).rstrip(b"\0")
                if segment != b"__TEXT" or owner != b"__TEXT" or name != b"__entitlements":
                    continue
                if result is not None:
                    raise ValueError("Duplicate Simulator entitlement sections")
                length = struct.unpack(endian + "Q", _range(data, section + 40, 8))[0]
                start = struct.unpack(endian + "I", _range(data, section + 48, 4))[0]
                try:
                    result = plistlib.loads(_range(data, start, length).rstrip(b"\0"))
                except (plistlib.InvalidFileException, ValueError, OverflowError) as error:
                    raise ValueError("Invalid embedded Simulator entitlement plist") from error
                if not isinstance(result, dict):
                    raise ValueError("Simulator entitlements must be a dictionary")
        offset += size
    if offset != command_end:
        raise ValueError("Mach-O load command sizes do not match the header")
    if result is None:
        raise ValueError("Missing __TEXT,__entitlements Simulator section")
    return _ARCHITECTURES[cpu], result


def read_simulator_entitlements(path: str | Path) -> dict[str, dict]:
    """Return arm64/x86_64 architecture plists from a thin or FAT32 Mach-O file.

    File offsets are interpreted relative to each bounded architecture slice.
    Unsupported architectures, missing sections, malformed ranges and duplicate
    architecture entries fail closed. This does not inspect the host signature.
    """
    data = Path(path).read_bytes()
    magic = _range(data, 0, 4)
    if magic not in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
        architecture, value = _thin_entitlements(data)
        return {architecture: value}
    endian = ">" if magic == b"\xca\xfe\xba\xbe" else "<"
    count = struct.unpack(endian + "I", _range(data, 4, 4))[0]
    if count == 0 or count > (len(data) - 8) // 20:
        raise ValueError("Invalid FAT32 architecture count")
    header_end = 8 + count * 20
    result: dict[str, dict] = {}
    slices: list[tuple[int, int]] = []
    for index in range(count):
        cpu, _, start, length, _ = struct.unpack(endian + "5I", _range(data, 8 + index * 20, 20))
        if start < header_end or length < 32 or any(start < end and begin < start + length for begin, end in slices):
            raise ValueError("Invalid or overlapping FAT32 architecture slices")
        architecture, value = _thin_entitlements(_range(data, start, length), expected_cpu=cpu)
        if architecture in result:
            raise ValueError("Duplicate FAT32 architecture")
        slices.append((start, start + length))
        result[architecture] = value
    return result
