# WCH CH347 Linux SDK Files

This directory contains the CH347 Linux SDK files copied from the local WCH
package at `/home/yuan/下载/ch341par_linux` for board bring-up convenience.

Included files:

- `ch347_lib.h`: CH347 user-space library declarations.
- `lib/x64/libch347.so`: x86-64 dynamic library used by `build/ch347_control` by
  default.
- `driver/`: WCH `ch34x_pis` kernel driver source and Makefile.

Build and load the driver manually when needed:

```bash
make -C third_party/ch347_linux/driver
sudo make -C third_party/ch347_linux/driver load
```

Unload it with:

```bash
sudo make -C third_party/ch347_linux/driver unload
```

Generated kernel build outputs under `driver/` should not be committed.
