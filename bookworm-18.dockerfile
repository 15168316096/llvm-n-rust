FROM docker.io/buildpack-deps:bookworm AS builder
LABEL maintainer="Xuejie Xiao <xxuejie@gmail.com>"

RUN apt-get update \
  && apt-get install -y --no-install-recommends cmake \
  && rm -rf /var/lib/apt/lists/*

ARG LLVM_TARBALL_SHA256="59abea1c22e64933fad4de1671a61cdb934098793c7a31b333ff58dc41bff36c"
WORKDIR /tmp/llvm-project
RUN curl -LO https://github.com/llvm/llvm-project/archive/llvmorg-19.1.7.tar.gz \
  && echo "${LLVM_TARBALL_SHA256}  llvmorg-19.1.7.tar.gz" | sha256sum -c -
# For local development, uncomment this(and comment the above line) to save the effort
# of downloading LLVM archives multiple times
# COPY llvmorg-19.1.7.tar.gz /tmp/llvm-project/llvmorg-19.1.7.tar.gz
RUN mkdir -p /llvm \
  && sha256sum llvmorg-19.1.7.tar.gz > /llvm/tarball_checksum.txt \
  && tar xzf llvmorg-19.1.7.tar.gz --strip-components=1 \
  && rm llvmorg-19.1.7.tar.gz

WORKDIR /tmp/llvm-project/clang-build
RUN cmake ../llvm \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/llvm \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_TARGETS_TO_BUILD="X86;AArch64;RISCV" \
  -DLLVM_LINK_LLVM_DYLIB=ON
RUN make -j$(nproc) && make install

FROM docker.io/buildpack-deps:bookworm
LABEL maintainer="Xuejie Xiao <xxuejie@gmail.com>"

RUN apt-get update \
  && apt-get install -y --no-install-recommends cmake \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /llvm /llvm
RUN find /llvm/bin -not -type d -exec ln -s {} {}-18 \;
ENV LLVM_HOME=/llvm \
    PATH="${PATH}:/llvm/bin"

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh \
  && sh /tmp/rustup-init.sh -y --default-toolchain 1.85.1 --target riscv64imac-unknown-none-elf \
  && rm /tmp/rustup-init.sh
ENV PATH="${PATH}:/root/.cargo/bin"

WORKDIR /code
