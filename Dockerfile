# Use ubuntu:20.04 as base for builder stage image
FROM ubuntu:24.04 as builder

# Set Salvium branch/tag to be used for salviumd compilation

ARG MONERO_BRANCH=develop

# Added DEBIAN_FRONTEND=noninteractive to workaround tzdata prompt on installation
ENV DEBIAN_FRONTEND="noninteractive"

# Install dependencies for monerod and xmrblocks compilation
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    cmake \
    miniupnpc \
    graphviz \
    doxygen \
    pkg-config \
    ca-certificates \
    zip \
    libboost-all-dev \
    libunbound-dev \
    libunwind8-dev \
    libssl-dev \
    libcurl4-openssl-dev \
    libgtest-dev \
    libreadline-dev \
    libzmq3-dev \
    libsodium-dev \
    libhidapi-dev \
    libhidapi-libusb0 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Set compilation environment variables
ENV CFLAGS='-fPIC'
ENV CXXFLAGS='-fPIC'
ENV USE_SINGLE_BUILDDIR=1
ENV BOOST_DEBUG=1
ENV MONERO_DIR="/root/salvium"

WORKDIR /root

# Clone and compile monerod with all available threads
ARG NPROC
RUN git clone --recursive --branch ${MONERO_BRANCH} https://github.com/salvium/salvium.git \
    && cd salvium \
    && test -z "$NPROC" && nproc > /nproc || echo -n "$NPROC" > /nproc && make -j"$(cat /nproc)" release

# Remove the MX25519 shared lib - xmrblocks needs the static build
RUN rm /root/salvium/build/release/external/mx25519/libmx25519.so

# Copy and cmake/make xmrblocks with all available threads
COPY . /root/salvium-blockchain-explorer/
WORKDIR /root/salvium-blockchain-explorer/build
RUN MONERO_DIR=/root/salvium cmake .. && make -j"$(cat /nproc)"

# Use ldd and awk to bundle up dynamic libraries for the final image
RUN zip /lib.zip $(ldd xmrblocks | grep -E '/[^\ ]*' -o)

# Use ubuntu:20.04 as base for final image
FROM ubuntu:24.04

# Added DEBIAN_FRONTEND=noninteractive to workaround tzdata prompt on installation
ENV DEBIAN_FRONTEND="noninteractive"

# Install unzip to handle bundled libs from builder stage
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends unzip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /lib.zip .
RUN unzip -o lib.zip && rm -rf lib.zip

# Add user and setup directories for salviumd and xmrblocks
RUN useradd -ms /bin/bash salvium \
    && mkdir -p /home/salvium/.salvium \
    && chown -R salvium:salvium /home/salvium/.salvium
USER salvium

# Switch to home directory and install newly built xmrblocks binary
WORKDIR /home/salvium
COPY --chown=salvium:salvium --from=builder /root/salvium-blockchain-explorer/build/xmrblocks .
COPY --chown=salvium:salvium --from=builder /root/salvium-blockchain-explorer/build/templates ./templates/

# Expose volume used for lmdb access by xmrblocks
VOLUME /home/salvium/.salvium

# Expose default explorer http port
EXPOSE 8081

ENTRYPOINT ["/bin/sh", "-c"]

# Set sane defaults that are overridden if the user passes any commands
CMD ["./xmrblocks --enable-json-api --enable-autorefresh-option  --enable-pusher"]
