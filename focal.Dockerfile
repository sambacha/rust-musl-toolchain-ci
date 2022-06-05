FROM ubuntu:focal-20220404
# # Install Rust using rustup.
RUN apt-get update && apt-get install -y curl
ARG RUST_VERSION
ARG TARGET
ARG RUST_PREFIX
ENV RUSTUP_HOME=$RUST_PREFIX
ENV CARGO_HOME=$RUST_PREFIX
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain $RUST_VERSION --target "$TARGET"
ENV PATH="$RUST_PREFIX/bin:$PATH"

ARG CLANG_PREFIX
COPY --from=clang-builder $CLANG_PREFIX $CLANG_PREFIX
ENV PATH="$CLANG_PREFIX/bin:$PATH"

ARG LIBS_PREFIX
COPY --from=libs-builder $LIBS_PREFIX $LIBS_PREFIX
ENV PATH="$LIBS_PREFIX/bin:$PATH"

# # Essential tools needed for compiling native dependencies
RUN apt-get update && apt-get install -y --install-recommends build-essential cmake git

# # Because the system GCC and binutils are shadowed by aliases, we need to
# # instruct Cargo and cc crate to use GCC on the host system. They are used to
# # compile dependencies of build scripts.
RUN echo \
    "#!/bin/sh\n"\
    "/usr/bin/gcc -B/usr/bin \$@\n"\
    "exit \$?" > $LIBS_PREFIX/bin/gnu-cc && chmod +x $LIBS_PREFIX/bin/gnu-cc
RUN echo \
    "#!/bin/sh\n"\
    "/usr/bin/g++ -B/usr/bin \$@\n"\
    "exit \$?" > $LIBS_PREFIX/bin/gnu-c++ && chmod +x $LIBS_PREFIX/bin/gnu-c++

ENV CC_x86_64_unknown_linux_gnu=gnu-cc
ENV CXX_x86_64_unknown_linux_gnu=gnu-c++
ENV LD_x86_64_unknown_linux_gnu=/usr/bin/ld
ENV AR_x86_64_unknown_linux_gnu=/usr/bin/ar

ENV CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=gnu-cc

# # # Set up environment for pkg-config
ENV PKG_CONFIG_PATH=$LIBS_PREFIX/lib/pkgconfig
ENV PKG_CONFIG_ALLOW_CROSS=1

# # Set up environment variables for Rust bindgen
# # See https://github.com/rust-lang/rust-bindgen/issues/1229#issuecomment-473493753
ENV BINDGEN_EXTRA_CLANG_ARGS="--sysroot=/opt/libs -target $TARGET"

# # Set default Cargo target
RUN mkdir -p ~/.cargo
RUN echo -e "[build]\ntarget = \"$TARGET\"" > ~/.cargo/config
