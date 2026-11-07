"""Pure-Python binding for /dev/xlr8 (no compiled code, works in Jupyter on the board).

    import xlr8
    with xlr8.Device() as gpu:
        gpu.load_file("ball.hex")
        gpu.alloc(0x20000)                       # GPU word w is gpu.words[w]
        gpu.words[0x2000:0x2005] = [cx, cy, 49, ball, bg]
        res = gpu.run(threads=4096, src=0x2000, dst=0x6000)
        frame = gpu.words[0x6000:0x6000 + 4096]
"""
import fcntl
import mmap
import os
import struct

XLR8_ID = 0x584C5238
MAX_PROG = 1024
MAX_BUF = 64 << 20
ST_DONE, ST_ERROR, ST_BAD_ACCESS, ST_TIMEOUT, ST_ABORTED = 1 << 1, 1 << 2, 1 << 3, 1 << 16, 1 << 17

_IOC_WRITE, _IOC_READ = 1, 2


def _ioc(d, nr, size):
    return (d << 30) | (size << 16) | (ord("X") << 8) | nr


# struct sizes from driver/xlr8_uapi.h
_INFO = struct.Struct("<16I")
_PROG = struct.Struct("<QI3I")
_BUF = struct.Struct("<4I")
_SUBMIT = struct.Struct("<8I")
_WAIT = struct.Struct("<10I")
GET_INFO = _ioc(_IOC_READ, 0, _INFO.size)
LOAD_PROG = _ioc(_IOC_WRITE, 1, _PROG.size)
SET_BUF = _ioc(_IOC_READ | _IOC_WRITE, 2, _BUF.size)
SUBMIT = _ioc(_IOC_WRITE, 3, _SUBMIT.size)
WAIT = _ioc(_IOC_READ | _IOC_WRITE, 4, _WAIT.size)


class Result:
    def __init__(self, status, cycles, xacts, stalls, err_addr):
        self.status, self.cycles, self.xacts, self.stalls, self.err_addr = status, cycles, xacts, stalls, err_addr

    @property
    def ok(self):
        return not (self.status & (ST_ERROR | ST_TIMEOUT | ST_ABORTED))

    def __repr__(self):
        return (f"Result(status={self.status:#x}, cycles={self.cycles}, xacts={self.xacts}, "
                f"stalls={self.stalls}, err_addr={self.err_addr:#x})")


class Device:
    def __init__(self, path="/dev/xlr8"):
        self.fd = os.open(path, os.O_RDWR | os.O_CLOEXEC)
        self._map = None
        self.words = None

    def close(self):
        self.words = None
        if self._map is not None:
            self._map.close()
            self._map = None
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()

    def info(self):
        v = struct.unpack("<16I", fcntl.ioctl(self.fd, GET_INFO, bytearray(_INFO.size)))
        return dict(uapi_version=v[0], id=v[1], hw_version=v[2], status=v[3], max_prog_instrs=v[4], buf_size=v[5])

    def load(self, instrs):
        n = len(instrs)
        if not 1 <= n <= MAX_PROG:
            raise ValueError("program must have 1..%d instructions" % MAX_PROG)
        raw = struct.pack("<%dH" % n, *instrs)
        buf = bytearray(raw)
        import ctypes
        addr = ctypes.addressof((ctypes.c_char * len(buf)).from_buffer(buf))
        fcntl.ioctl(self.fd, LOAD_PROG, _PROG.pack(addr, n, 0, 0, 0))

    def load_file(self, path):
        if path.endswith(".hex"):
            instrs = [int(t, 16) for line in open(path) for t in line.split()]
        else:
            data = open(path, "rb").read()
            instrs = list(struct.unpack("<%dH" % (len(data) // 2), data[: len(data) // 2 * 2]))
        self.load(instrs)

    def alloc(self, nbytes):
        if not 0 < nbytes <= MAX_BUF:
            raise ValueError("bad buffer size")
        out = fcntl.ioctl(self.fd, SET_BUF, _BUF.pack(nbytes, 0, 0, 0))
        size = struct.unpack("<4I", out)[0]
        self.words = None
        if self._map is not None:
            self._map.close()
        self._map = mmap.mmap(self.fd, size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
        self.words = memoryview(self._map).cast("I")      # 32-bit accesses, GPU word index
        return size

    def submit(self, threads, src, dst, prog_base=0):
        fcntl.ioctl(self.fd, SUBMIT, _SUBMIT.pack(threads, src, dst, prog_base, 0, 0, 0, 0))

    def wait(self, timeout_ms=0):
        out = fcntl.ioctl(self.fd, WAIT, _WAIT.pack(timeout_ms, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        v = struct.unpack("<10I", out)
        return Result(v[2] | ST_DONE, v[3], v[4], v[5], v[6])

    def run(self, threads, src, dst, prog_base=0, timeout_ms=0):
        self.submit(threads, src, dst, prog_base)
        return self.wait(timeout_ms)
