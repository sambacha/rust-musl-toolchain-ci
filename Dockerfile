# A version like "1.38.0" or "nightly-2019-11-01".
ARG RUST_VERSION
# We use Clang and libc++ from LLVM. The commit should match the one
# used by Rust. For each Rust version it can be found here
# https://github.com/rust-lang/rust/tree/master/src as the commit hash of the
# submodule "llvm-project". Example "71fe7ec06b85f612fc0e4eb4134c7a7d0f23fac5".
ARG LLVM_GIT_COMMIT
# The version of musl should be the same as the one Rust is compiled with.
# This version can be found in this file:
# https://github.com/rust-lang/rust/blob/master/src/ci/docker/scripts/musl-toolchain.sh.
# Exampel: "1.1.22".
ARG MUSL_VERSION

# LLVM target triple for Linux and MUSL. Full list of supported triples
# can be found here:
# https://forge.rust-lang.org/release/platform-support.html.
# Example: "armv7-unknown-linux-musleabihf".
ARG TARGET
# We also need GCC for the target architecture to compile compier-rt. Because
# GCC target triples are different from LLVM, we need to specify it explicitly.
# Example: "arm-linux-gnueabihf".
ARG GNU_TARGET

ARG LTO="thin"

# Used by libc++. Programs compiled with this version should work with other
# kernel versions too. See https://wiki.gentoo.org/wiki/Linux-headers#FAQ.
ARG LINUX_HEADERS_VERSION=5.3.1

# Locations for produced tools and libraries.
ARG RUST_PREFIX=/opt/rust
ARG CLANG_PREFIX=/opt/clang
ARG LIBS_PREFIX=/opt/libs

# Independent components are built in different stages, so that
# change of individual arguments would rebuild only affected stages.

# LLVM source tree is shared by both clang and libs builder stages.
FROM ubuntu:18.04 AS llvm-source
RUN apt-get update && apt-get install -y git
ENV SRC_DIR=/src
WORKDIR $SRC_DIR
ARG LLVM_GIT_COMMIT
RUN git clone https://github.com/rust-lang/llvm-project.git && \
  cd llvm-project && \
  git checkout $LLVM_GIT_COMMIT && \
  rm -rf .git
ENV LLVM_DIR=$SRC_DIR/llvm-project

# Clang
FROM llvm-source AS clang-builder
RUN apt-get update && apt-get -y install build-essential ninja-build cmake python3-distutils
ARG CLANG_PREFIX
WORKDIR $LLVM_DIR
RUN mkdir build && \
  cd build && \
  cmake \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_INSTALL_BINUTILS_SYMLINKS=ON \
  -DCMAKE_BUILD_TYPE=release \
  -DCMAKE_INSTALL_PREFIX=$CLANG_PREFIX \
  -G Ninja \
  ../llvm && \
  cmake --build . --target install

# Libs
FROM llvm-source AS libs-builder

ARG CLANG_PREFIX
COPY --from=clang-builder $CLANG_PREFIX $CLANG_PREFIX
ENV PATH="$CLANG_PREFIX/bin:$PATH"

# Get all sources at first, so that changes in arguments
# flags would not redownload them.
RUN apt-get update && apt-get -y install curl xz-utils

ARG MUSL_VERSION
RUN curl --proto '=https' --tlsv1.2 -sSf \
  https://www.musl-libc.org/releases/musl-$MUSL_VERSION.tar.gz | \
  tar xzf -
ENV MUSL_DIR $SRC_DIR/musl-$MUSL_VERSION

ARG LINUX_HEADERS_VERSION
RUN curl --proto '=https' --tlsv1.2 -sSf \
  https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-$LINUX_HEADERS_VERSION.tar.xz > linux-$LINUX_HEADERS_VERSION.tar.xz && \
  tar xJvf linux-$LINUX_HEADERS_VERSION.tar.xz && \
  rm linux-$LINUX_HEADERS_VERSION.tar.xz
ENV LINUX_DIR $SRC_DIR/linux-$LINUX_HEADERS_VERSION

# Install build dependencies.
RUN apt-get update && apt-get -y install rsync ninja-build cmake python3-distutils 

ARG TARGET
ARG LIBS_PREFIX

# Compile Clang runtime (https://compiler-rt.llvm.org).
# We need crtbegin.o, crtend.o, and libclang_rt.builtins.a from there.
# Because Clang toolchain is not fully bootstrapped yet (no standard library),
# it is necessary to use GCC to compile it.
ARG GNU_TARGET
RUN apt-get install -y gcc${GNU_TARGET:+-${GNU_TARGET}} g++${GNU_TARGET:+-${GNU_TARGET}}
WORKDIR $LLVM_DIR/compiler-rt
ENV CC=${GNU_TARGET:+${GNU_TARGET}-}gcc
ENV CXX=${GNU_TARGET:+${GNU_TARGET}-}g++
ENV CFLAGS=""
ENV CXXFLAGS=""
ENV LDFLAGS=""
RUN mkdir build && \
  cd build && \
  cmake \
    -DCMAKE_BUILD_TYPE=release \
    -DLLVM_CONFIG_PATH=$CLANG_PREFIX/bin/llvm-config \
		-DCOMPILER_RT_DEFAULT_TARGET_TRIPLE=$TARGET \
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
    -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DCOMPILER_RT_BUILD_XRAY=OFF \
    -DCOMPILER_RT_BUILD_PROFILE=OFF \
    -DCMAKE_INSTALL_PREFIX=$LIBS_PREFIX \
    -G Ninja \
    .. && \
  cmake --build . --target install

# Compile musl.
WORKDIR $MUSL_DIR
ENV CC=clang
ENV CFLAGS="-target $TARGET -nostdinc -isystem $LIBS_PREFIX/include -D_Noreturn="
ENV LDFLAGS="-fuse-ld=lld -static -nostdlib -nostartfiles"
ENV CROSS_COMPILE=$CLANG_PREFIX/bin/
ENV cd $MUSL_DIR && pwd && ls -lha && \
  mkdir build && \
  cd build && \
  ../configure \
  --target=$TARGET \
  --prefix=$LIBS_PREFIX \
  --disable-shared \
  --disable-gcc-wrapper && \
  make -j$(nproc) install

# Install Linux headers.
WORKDIR $LINUX_DIR
ENV CC=clang
ENV CFLAGS="-target $TARGET -nostdinc -isystem $LIBS_PREFIX/include"
ENV LDFLAGS="-fuse-ld=lld -static -nostdlib -nostartfiles"
RUN cd $LINUX_DIR && pwd && ls -lha && make -j$(nproc) headers_install \
  KBUILD_VERBOSE=1 \
  HOSTCC="/usr/bin/gcc" \
  $(if [ -n "$GNU_TARGET" ]; then echo "ARCH=$GNU_TARGET" | cut -d- -f1; fi) \
  CC="$CC" \
  INSTALL_HDR_PATH=$LIBS_PREFIX

# # Compile libc++ with musl using Clang as the compiler. See
# # https://blogs.gentoo.org/gsoc2016-native-clang/2016/05/05/build-a-freestanding-libcxx/
# # for explanations.

# # libunwind
# WORKDIR $LLVM_DIR/libunwind
# ENV CC=clang
# ENV CXX=clang++
# ENV CFLAGS="-target $TARGET -nostdinc -isystem $LIBS_PREFIX/include"
# ENV CXXFLAGS="$CFLAGS -nostdinc++ -I$LLVM_DIR/libcxx/include"
# ENV LDFLAGS="-fuse-ld=lld -static -nostdlib -nostartfiles -L$LIBS_PREFIX/lib -lc"
# RUN mkdir build && \
#   cd build && \
#   cmake \
#   -DCMAKE_BUILD_TYPE=release \
#   -DLIBUNWIND_ENABLE_SHARED=OFF \
#   -DLIBUNWIND_INSTALL_PREFIX=$LIBS_PREFIX/ \
#   -DLLVM_PATH=$LLVM_DIR \
#   -G Ninja \
#   .. && \
#   cmake --build . --target install

# # libc++abi
# WORKDIR $LLVM_DIR/libcxxabi
# ENV CC=clang
# ENV CXX=clang++
# ENV CFLAGS="-target $TARGET -nostdinc -isystem $LIBS_PREFIX/include"
# ENV CXXFLAGS="$CFLAGS -nostdinc++ -I$LLVM_DIR/libcxx/include"
# ENV LDFLAGS="-fuse-ld=lld -static -nostdlib -nostartfiles -L$LIBS_PREFIX/lib -lunwind -lc"
# RUN mkdir build && \
#   cd build && \
#   cmake \
#   -DCMAKE_BUILD_TYPE=release \
#   -DLIBCXXABI_ENABLE_SHARED=OFF \
#   -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
#   -DLIBCXXABI_LIBUNWIND_PATH=$LLVM_DIR/libunwind \
#   -DLIBCXXABI_LIBCXX_INCLUDES=$LLVM_DIR/libcxx/include \
#   -DLIBCXXABI_INSTALL_PREFIX=$LIBS_PREFIX/ \
#   -DLLVM_PATH=$LLVM_DIR \
#   -G Ninja \
#   .. && \
#   cmake --build . --target install

# # libc++
# WORKDIR $LLVM_DIR/libcxx
# ENV CC=clang
# ENV CXX=clang++
# ENV CFLAGS="-target $TARGET -nostdinc -isystem $LIBS_PREFIX/include"
# ENV CXXFLAGS="$CFLAGS -nostdinc++ -I$LIBS_PREFIX/include/c++/v1"
# ENV LDFLAGS="-fuse-ld=lld -static -nostdlib -nostartfiles -L$LIBS_PREFIX/lib -lc++abi -lunwind -lc"
# RUN mkdir build && \
#   cd build && \
#   cmake \
#   -DCMAKE_BUILD_TYPE=release \
#   -DLIBCXX_ENABLE_SHARED=OFF \
#   -DLIBCXX_HAS_MUSL_LIBC=ON \
#   -DLIBCXX_HAS_GCC_S_LIB=OFF \
#   -DLIBCXX_CXX_ABI=libcxxabi \
#   -DLIBCXX_CXX_ABI_INCLUDE_PATHS=$LLVM_DIR/libcxxabi/include \
#   -DLIBCXX_CXX_ABI_LIBRARY_PATH=$LIBS_PREFIX \
#   -DLIBCXX_INSTALL_PREFIX=$LIBS_PREFIX/ \
#   -DLIBCXX_INSTALL_HEADER_PREFIX=$LIBS_PREFIX/ \
#   -DLLVM_PATH=$LLVM_DIR \
#   -G Ninja \
#   .. && \
#   cmake --build . --target install

# # Create wrappers for Clang that automatically use correct libraries and start files.
# # See
# # https://blogs.gentoo.org/gsoc2016-native-clang/2016/05/31/build-gnu-free-executables-with-clang/
# # and
# # https://renenyffenegger.ch/notes/development/languages/C-C-plus-plus/GCC/options/no/compare-nostartfiles-nodefaultlibs-nolibc-nostdlib.
# ENV MUSL_CFLAGS="-target $TARGET -nostdinc -isystem $LIBS_PREFIX/include"
# ENV MUSL_CXXFLAGS="$MUSL_CFLAGS -nostdinc++ -I$LIBS_PREFIX/include/c++/v1"

# ENV MUSL_LDFLAGS="-fuse-ld=lld -static -nostdlib -nostartfiles -L$LIBS_PREFIX/lib -L$LIBS_PREFIX/lib/linux -lc++ -lc++abi -lunwind -l$(ls $LIBS_PREFIX/lib/linux/clang_rt.builtins*) -lc"
# ENV MUSL_STARTFILES="$LIBS_PREFIX/lib/crt1.o $(find $LIBS_PREFIX/lib/linux -iname 'clang_rt.crtbegin*.o') $(find $LIBS_PREFIX/lib/linux -iname 'clang_rt.crtend*.o')"

# RUN mkdir -p $LIBS_PREFIX/bin
# RUN echo \
#   "#!/bin/sh\n"\
#   "case \"\$@\" in *-shared*);; *-nostdlib*);; *) STARTFILES=\"$MUSL_STARTFILES\";; esac\n"\
#   "$CLANG_PREFIX/bin/clang -Qunused-arguments $MUSL_CFLAGS \$@ \$STARTFILES $MUSL_LDFLAGS\n"\
#   "exit \$?" > $LIBS_PREFIX/bin/musl-cc
# RUN echo \
#   "#!/bin/sh\n"\
#   "case \"\$@\" in *-shared*);; *-nostdlib*);; *) STARTFILES=\"$MUSL_STARTFILES\";; esac\n"\
#   "$CLANG_PREFIX/bin/clang++ -Qunused-arguments $MUSL_CXXFLAGS \$@ \$STARTFILES $MUSL_LDFLAGS\n"\
#   "exit \$?" > $LIBS_PREFIX/bin/musl-c++
# RUN chmod +x $LIBS_PREFIX/bin/*

# # At this point a fully functional C++ compiler that is able to produce
# # static binaries linked with musl and libc++ is bootstrapped.
# # It can be used by calling musl-c++ (or musl-cc for C) executable.
# # However, we need to also create generic aliases to make it possible to
# # use it as a drop-in replacement for the system-wide GCC.
# RUN ln -s $LIBS_PREFIX/bin/musl-cc $LIBS_PREFIX/bin/cc
# RUN ln -s $LIBS_PREFIX/bin/musl-cc $LIBS_PREFIX/bin/gcc
# RUN if [ -n "$GNU_TARGET" ]; then ln -s $LIBS_PREFIX/bin/musl-cc $LIBS_PREFIX/bin/$(echo $GNU_TARGET | sed 's/gnu/musl/g')-gcc; fi
# RUN ln -s $LIBS_PREFIX/bin/musl-cc $LIBS_PREFIX/bin/musl-gcc
# RUN ln -s $LIBS_PREFIX/bin/musl-c++ $LIBS_PREFIX/bin/c++
# RUN ln -s $LIBS_PREFIX/bin/musl-c++ $LIBS_PREFIX/bin/g++
# RUN if [ -n "$GNU_TARGET" ]; then ln -s $LIBS_PREFIX/bin/musl-c++ $LIBS_PREFIX/bin/$(echo $GNU_TARGET | sed 's/gnu/musl/g')-g++; fi
# RUN ln -s $LIBS_PREFIX/bin/musl-c++ $LIBS_PREFIX/bin/musl-g++

# RUN ln -s $CLANG_PREFIX/bin/ar $LIBS_PREFIX/bin/arm-linux-musleabihf-ar

# # Use stdatomic.h header provided by Clang because it is not present in musl.
# RUN ln -s $CLANG_PREFIX/lib/clang/9.0.0/include/stdatomic.h $LIBS_PREFIX/include/stdatomic.h

# # Some build scripts hardcode -lstdc++ linker flag on all Linux systems.
# # Because our linker is already configured to link with libc++ instead,
# # we can just provide dummy libstdc++ to be compatible with GNU systems.
# # For example, macOS provides similar experience, where
# # `clang++ -o program program.cpp -lstdc++` would still link to libc++.
# RUN echo > dummy.c && \
#   $LIBS_PREFIX/bin/cc -c dummy.c && \
#   $CLANG_PREFIX/bin/ar cr $LIBS_PREFIX/lib/libstdc++.a dummy.o && \
#   rm dummy.c dummy.o

# # The actual builder.
# FROM ubuntu:18.04

# # Install Rust using rustup.
# RUN apt-get update && apt-get install -y curl
# ARG RUST_VERSION
# ARG TARGET
# ARG RUST_PREFIX
# ENV RUSTUP_HOME=$RUST_PREFIX
# ENV CARGO_HOME=$RUST_PREFIX
# RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
#   sh -s -- -y --default-toolchain $RUST_VERSION --target "$TARGET"
# ENV PATH="$RUST_PREFIX/bin:$PATH"

# ARG CLANG_PREFIX
# COPY --from=clang-builder $CLANG_PREFIX $CLANG_PREFIX
# ENV PATH="$CLANG_PREFIX/bin:$PATH"

# ARG LIBS_PREFIX
# COPY --from=libs-builder $LIBS_PREFIX $LIBS_PREFIX
# ENV PATH="$LIBS_PREFIX/bin:$PATH"

# # Essential tools needed for compiling native dependencies
# RUN apt-get update && apt-get install -y --install-recommends build-essential cmake git

# # Because the system GCC and binutils are shadowed by aliases, we need to
# # instruct Cargo and cc crate to use GCC on the host system. They are used to
# # compile dependencies of build scripts.
# RUN echo \
#   "#!/bin/sh\n"\
#   "/usr/bin/gcc -B/usr/bin \$@\n"\
#   "exit \$?" > $LIBS_PREFIX/bin/gnu-cc && chmod +x $LIBS_PREFIX/bin/gnu-cc
# RUN echo \
#   "#!/bin/sh\n"\
#   "/usr/bin/g++ -B/usr/bin \$@\n"\
#   "exit \$?" > $LIBS_PREFIX/bin/gnu-c++ && chmod +x $LIBS_PREFIX/bin/gnu-c++

# ENV CC_x86_64_unknown_linux_gnu=gnu-cc
# ENV CXX_x86_64_unknown_linux_gnu=gnu-c++
# ENV LD_x86_64_unknown_linux_gnu=/usr/bin/ld
# ENV AR_x86_64_unknown_linux_gnu=/usr/bin/ar

# ENV CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=gnu-cc

# # # Set up environment for pkg-config
# # ENV PKG_CONFIG_PATH=$LIBS_PREFIX/lib/pkgconfig
# # ENV PKG_CONFIG_ALLOW_CROSS=1

# # Set up environment variables for Rust bindgen
# # See https://github.com/rust-lang/rust-bindgen/issues/1229#issuecomment-473493753
# ENV BINDGEN_EXTRA_CLANG_ARGS="--sysroot=/opt/libs -target $TARGET"

# # Set default Cargo target
# RUN mkdir -p ~/.cargo
# RUN echo -e "[build]\ntarget = \"$TARGET\"" > ~/.cargo/config

# # In case of non-native target, install QEMU-user to enable runing `cargo test`
# RUN if [ -n "$GNU_TARGET"]; then apt-get update && apt-get install -y qemu-user; fi
