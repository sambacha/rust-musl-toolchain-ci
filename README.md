# rust `musl` toolchain

> Rust `musl` toolchain, used to compile `rust-musl` release binaries.

## Motivation
* Produce statically-linked binaries for `x86_64` and `armv7` Linux
* Use `musl` as the standard C library
* Use `libc++` as the standard C++ library
* Leverage `clang` and `lld` to enable cross-language link-time optimization

## Usage

In order to build your project for a given target, run

```shell
docker run -w"$PWD" -v"$PWD":"$PWD" -t manifoldfinance/rust-toolchain:1.60.0-armv7-unknown-linux-musl cargo build
```

Alternative, just create a shell alias

```shell
alias cargo-armv7='docker run -w"$PWD" -v"$PWD":"$PWD" -t manifoldfinance/rust-toolchain:1.60.0-armv7-unknown-linux-musl cargo'
```

In order to be able to run `cargo-armv7 build`, `cargo-armv7 test`, etc.

> NOTE. that the tests should work too, although they are compiled for the target platform, with help of user-mode QEMU installed inside the toolchain image.

## License

This project is licensed under [Apache License, Version 2.0](LICENSE).
