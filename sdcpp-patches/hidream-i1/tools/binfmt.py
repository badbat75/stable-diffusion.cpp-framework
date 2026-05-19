"""Shared .bin (de)serialiser for HiDream-I1 step-5 numerical validation.

On-disk format == what sd.cpp's `sd::load_tensor_from_file_as_tensor`
(tensor_ggml.hpp) reads and `HiDreamI1::dump_f32` (hidream_i1.hpp) writes:

    int32  n_dims
    int32  name_len            (always 0 here)
    int32  ttype               (0 == GGML_TYPE_F32)
    int32  dims[n_dims]        sd/ggml order  ==  REVERSED numpy .shape
    char   name[name_len]      (none)
    float32 data[...]          C-contiguous

The dim reversal is the whole trick: ggml ne[0] is the fastest-varying
axis, numpy's is the last. Writing `reversed(arr.shape)` + C-contiguous
bytes makes the linear layout identical on both sides, so a flat compare
of the same logical tensor is valid with no transpose.
"""

import struct
import numpy as np


def write_bin(path, arr):
    arr = np.ascontiguousarray(arr, dtype=np.float32)
    dims = list(reversed(arr.shape))  # numpy -> sd/ggml order
    with open(path, "wb") as f:
        f.write(struct.pack("<iii", len(dims), 0, 0))
        f.write(struct.pack("<%di" % len(dims), *dims))
        f.write(arr.tobytes(order="C"))


def read_bin(path):
    with open(path, "rb") as f:
        n_dims, name_len, ttype = struct.unpack("<iii", f.read(12))
        assert ttype == 0, "only f32 supported (got ttype=%d)" % ttype
        dims = list(struct.unpack("<%di" % n_dims, f.read(4 * n_dims)))
        f.read(name_len)
        data = np.frombuffer(f.read(), dtype=np.float32)
    # dims are sd/ggml order; numpy shape is the reverse.
    return data.reshape(list(reversed(dims)))
