# Syntax: docker/dockerfile:1
FROM swift:6.3-jammy AS build
WORKDIR /build

# Override host gitconfig that redirects HTTPS to SSH
RUN echo '[url "https://github.com/"]\n\tinsteadOf = git@github.com:' > /tmp/clean-gitconfig
ENV GIT_CONFIG_GLOBAL=/tmp/clean-gitconfig

COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY Sources ./Sources
COPY Tests ./Tests
COPY Public ./Public
RUN swift build -c release

# Runtime
FROM ubuntu:22.04
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libssl3 tzdata curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/lib/swift /usr/lib/swift
COPY --from=build /usr/lib/x86_64-linux-gnu/libicu*.so* /usr/lib/x86_64-linux-gnu/
ENV LD_LIBRARY_PATH=/usr/lib/swift/linux:/usr/lib/x86_64-linux-gnu:/usr/lib

WORKDIR /app
ENV TZ=Europe/Moscow

COPY --from=build /build/.build/release/Povar ./Povar
COPY --from=build /build/Public ./Public

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --retries=3 CMD curl -fs http://localhost:8080/health || exit 1

CMD ["./Povar", "serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
