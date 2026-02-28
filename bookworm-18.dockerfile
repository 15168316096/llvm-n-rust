FROM docker.io/buildpack-deps:bookworm as builder
MAINTAINER Xuejie Xiao <xxuejie@gmail.com>

RUN apt-get update && apt-get install -y cmake

RUN mkdir -p /tmp/llvm-project
WORKDIR /tmp/llvm-project
RUN curl -LO https://github.com/llvm/llvm-project/archive/llvmorg-19.1.7.tar.gz
# For local development, uncomment this(and comment the above line) to save the effort
# of downloading LLVM archives multiple times
# COPY llvmorg-19.1.7.tar.gz /tmp/llvm-project/llvmorg-19.1.7.tar.gz
RUN mkdir -p /llvm
RUN sha256sum llvmorg-19.1.7.tar.gz > /llvm/tarball_checksum.txt
RUN tar xzf llvmorg-19.1.7.tar.gz --strip-components=1 && rm llvmorg-19.1.7.tar.gz

RUN mkdir /tmp/llvm-project/clang-build
WORKDIR /tmp/llvm-project/clang-build
RUN cmake ../llvm \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/llvm \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_TARGETS_TO_BUILD="X86;AArch64;RISCV" \
  -DLLVM_LINK_LLVM_DYLIB=ON
# RUN make -j$(nproc)
RUN make -j2
RUN make install

FROM docker.io/buildpack-deps:bookworm
MAINTAINER Xuejie Xiao <xxuejie@gmail.com>

RUN apt-get update && apt-get install -y cmake

COPY --from=builder /llvm /llvm
RUN find /llvm/bin -not -type d -exec ln -s {} {}-18 \;
ENV LLVM_HOME /llvm
ENV PATH "${PATH}:${LLVM_HOME}/bin"

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- \
  -y --default-toolchain 1.85.1 --target riscv64imac-unknown-none-elf
ENV PATH "${PATH}:/root/.cargo/bin"

RUN mkdir /code
WORKDIR /code
