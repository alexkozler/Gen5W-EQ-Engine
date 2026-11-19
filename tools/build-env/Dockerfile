# Linux build environment for EQ Engine (Ubuntu 24.04, OpenJDK 21), for building on Windows or macOS
# through Docker. The Android NDK r25c is not in the image: keep it in a volume (see README.md,
# "Building from source").
#
#   docker build -t eqengine-build tools/build-env
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential openjdk-21-jdk-headless \
        python3 python3-numpy python3-pil python3-pip \
        zip unzip git dash mksh ca-certificates curl file fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/*
RUN pip3 install --no-cache-dir --break-system-packages unicorn
ENV NDK=/opt/ndk/android-ndk-r25c
WORKDIR /src
