# Base image with Go 1.21
FROM golang:1.22.3 AS builder

# Install dependencies
RUN apt-get update && apt-get install -y \
    git cmake make gcc libssl-dev pkg-config && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /chaincode

# Clone and build liboqs
RUN git clone --depth=1 https://github.com/open-quantum-safe/liboqs && \
    cmake -S liboqs -B liboqs/build -DBUILD_SHARED_LIBS=ON && \
    cmake --build liboqs/build --parallel 8 && \
    cmake --install liboqs/build

# Set environment variables
ENV LD_LIBRARY_PATH=/usr/local/lib
ENV PKG_CONFIG_PATH=/chaincode/liboqs-go/.config

# Clone and setup liboqs-go
RUN git clone --depth=1 https://github.com/open-quantum-safe/liboqs-go

# Copy chaincode source
COPY . .

# Build chaincode binary
RUN go mod tidy && go build -o chaincode

# Second stage: runtime container
FROM debian:bookworm-slim

# Setup tini to handle signals
ENV TINI_VERSION v0.19.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN chmod +x /tini

# Install dependencies for runtime
RUN apt-get update && apt-get install -y \
    libssl-dev ca-certificates && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /chaincode

# Copy compiled chaincode binary from the builder stage
COPY --from=builder /chaincode/chaincode /chaincode/chaincode

# ✅ Copy the compiled liboqs shared libraries from the builder stage
COPY --from=builder /usr/local/lib/liboqs.so* /usr/local/lib/

# ✅ Set the library path for runtime
ENV LD_LIBRARY_PATH=/usr/local/lib

# Copy the entrypoint script
COPY docker/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Set environment variables
ENV CHAINCODE_SERVER_PORT=9999
EXPOSE ${CHAINCODE_SERVER_PORT}

# Use non-root user
RUN addgroup --system chaincode && useradd -g chaincode chaincodeuser
USER chaincodeuser

# Entrypoint to start chaincode as a service
ENTRYPOINT [ "/tini", "--", "/docker-entrypoint.sh" ]
