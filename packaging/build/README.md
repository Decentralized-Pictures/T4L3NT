# Static binaries building

This directory contains various files required for building static
Tezos binaries:

* `build-libusb-and-hidapi.sh` script builds static version of libusb and hidapi
  libraries. It's required because default docker alpine image doesn't have static
  version for these libraries
* `static_libs.patch` patch file provides flags for dune files, these flags
  enable static linking for binaries.
