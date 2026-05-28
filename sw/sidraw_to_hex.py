#!/usr/bin/env python3
"""Convert a .sidraw file to a Verilog `$readmemh` hex file.

Output format: one byte per line as uppercase hex (`FF` or `00`), with
a leading comment line carrying the source filename and byte count.
This is the format `$readmemh` consumes (both Verilator and Quartus).

The output is intended to be placed alongside the .v source file that
references it -- by default the `$readmemh` path is resolved relative
to the source-file directory.

Usage:
  sidraw_to_hex.py <input.sidraw> <output.hex>
"""

import sys


def main() -> int:
  if len(sys.argv) != 3:
    sys.stderr.write(__doc__)
    return 1
  src, dst = sys.argv[1], sys.argv[2]
  with open(src, 'rb') as f:
    data = f.read()
  with open(dst, 'w') as f:
    f.write(f"// generated from {src} ({len(data)} bytes)\n")
    for b in data:
      f.write(f"{b:02X}\n")
  sys.stderr.write(f"wrote {len(data)} bytes to {dst}\n")
  return 0


if __name__ == '__main__':
  sys.exit(main())
