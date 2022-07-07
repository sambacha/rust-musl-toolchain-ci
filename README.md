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

> **Note**    
>  the tests should work too, although they are compiled for the target platform, with help of user-mode QEMU installed inside the toolchain image.

### Workflows

```yaml
name: ci
on: [push, pull_request]
jobs:
  lint:
    name: ${{ matrix.component }} ${{ matrix.os }}
    runs-on: ${{ matrix.os }}
    timeout-minutes: 15
    strategy:
      fail-fast: false
      matrix:
        include:
          - os: ubuntu-20.04
            target: x86_64-unknown-linux-musl
          - os: ubuntu-20.04
            binary: buildcache-dist

    steps:
      - name: Clone repository
        uses: actions/checkout@v3
        
      - name: Id
        id: id
        shell: bash
        run: echo "::set-output name=id::${ID#refs/tags/}"
        env:
          ID: ${{ startsWith(github.ref, 'refs/tags/') && github.ref || github.sha }}

      - name: Upload artifacts
        uses: actions/upload-artifact@v3
        with:
          name: ${{ matrix.binary || 'buildcache' }}-${{ steps.id.outputs.id }}-${{ matrix.target }}
          path: target/${{ matrix.target }}/release/${{ matrix.binary || 'buildcache' }}${{ endsWith(matrix.target, '-msvc') && '.exe' || '' }}
          if-no-files-found: error


  release:
    name: release
    runs-on: ubuntu-latest
    needs: [build, lint, test]
    if: ${{ startsWith(github.ref, 'refs/tags/') }}
    steps:
      - name: Clone repository
        uses: actions/checkout@v3

      - name: Get artifacts
        uses: actions/download-artifact@v3

      - name: Create release assets
        run: |
          for d in buildcache-*; do
            cp README.md LICENSE $d/
            tar -zcvf $d.tar.gz $d
            echo -n $(shasum -ba 256 $d.tar.gz | cut -d " " -f 1) > $d.tar.gz.sha256
          done
      - name: Create release
        run: |
          tag_name=${GITHUB_REF#refs/tags/}
          hub release create -m $tag_name $tag_name $(for f in buildcache-*.tar.gz*; do echo "-a $f"; done)
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          
```

This project is licensed under [Apache License, Version 2.0](LICENSE).
