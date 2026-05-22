# Dockerfile for the Fleet Console dashboard (Phoenix 1.8 + Elixir 1.18)
#
# Multi-stage release build. Produces a minimal, self-contained container
# that can run the full Phase 3 "Wow" console (device cards, dynamic devices,
# event log, cluster health, etc.).
#
# Primary usage:
#   docker build -t fleet-console .
#   docker run -p 4000:4000 -e MQTT_HOST=... fleet-console
#
# Recommended path for containerized demo:
#   docker compose --profile full up
#
# See docker-compose.yml and scripts/start-demo.sh for integration details.
# The image is intentionally only the dashboard; Mosquitto runs as a
# separate service in compose.
#
# @phase 2 (introduced) / Phase 3 (still valid)

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3
ARG DEBIAN_VERSION=bookworm-20241016-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS builder

# Install build dependencies
RUN apt-get update -y && apt-get install -y \
    build-essential \
    git \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files first for caching
COPY dashboard/mix.exs dashboard/mix.lock ./
RUN mix deps.get --only prod

# Copy the rest of the dashboard source
COPY dashboard/ ./

# Compile and build release
ENV MIX_ENV=prod
RUN mix compile
RUN mix phx.digest
RUN mix release --overwrite

# --- Runtime image ---
FROM debian:${DEBIAN_VERSION} AS runner

RUN apt-get update -y && apt-get install -y \
    libstdc++6 \
    openssl \
    ca-certificates \
    locales \
    && rm -rf /var/lib/apt/lists/*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app
COPY --from=builder /app/_build/prod/rel/fleet_monitor ./

# Expose Phoenix
EXPOSE 4000

# Default env (override at runtime; MQTT_HOST etc.)
ENV PHX_SERVER=true
ENV PORT=4000
ENV SECRET_KEY_BASE=please_generate_a_real_one_for_production

CMD ["bin/fleet_monitor", "start"]
