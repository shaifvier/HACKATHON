FROM golang:1.22.3 AS builder

ARG OQS_TAG=0.10.0
ARG OQS_GO_TAG=0.10.0

RUN apt-get update && apt-get install -y --no-install-recommends \
    git cmake make gcc libssl-dev pkg-config ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /chaincode

RUN git clone --depth=1 --branch ${OQS_TAG} https://github.com/open-quantum-safe/liboqs && \
    cmake -S liboqs -B liboqs/build -DBUILD_SHARED_LIBS=ON && \
    cmake --build liboqs/build --parallel 8 && \
    cmake --install liboqs/build

RUN git clone --depth=1 --branch ${OQS_GO_TAG} https://github.com/open-quantum-safe/liboqs-go

ENV LD_LIBRARY_PATH=/usr/local/lib
ENV PKG_CONFIG_PATH=/chaincode/liboqs-go/.config

COPY go.mod ./
COPY main.go ./
RUN go mod edit -require=github.com/open-quantum-safe/liboqs-go@0.10.0
RUN go mod tidy

RUN go build -o chaincode ./main.go

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates tini libssl-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /chaincode
COPY --from=builder /chaincode/chaincode /chaincode/chaincode
COPY --from=builder /usr/local/lib/liboqs.so* /usr/local/lib/
COPY docker-entrypoint.sh /docker-entrypoint.sh

RUN chmod +x /docker-entrypoint.sh

ENV LD_LIBRARY_PATH=/usr/local/lib
ENV CHAINCODE_SERVER_PORT=9999
EXPOSE 9999

ENTRYPOINT ["/usr/bin/tini", "--", "/docker-entrypoint.sh"]
