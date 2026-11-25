# Diapason web app, served by nginx. See docs/WEB_DOCKER.md.

# Flutter SDK image tag (https://github.com/cirruslabs/docker-images-flutter).
ARG FLUTTER_VERSION=3.44.0

# --- Build stage: compile the Flutter web app
FROM ghcr.io/cirruslabs/flutter:${FLUTTER_VERSION} AS builder
WORKDIR /app

# Resolve dependencies first so they are cached across source changes.
COPY pubspec.yaml pubspec.lock ./
COPY packages ./packages
RUN flutter pub get

COPY . .
RUN flutter gen-l10n && flutter build web --release --no-wasm-dry-run

# --- Runtime stage
FROM nginxinc/nginx-unprivileged:alpine-slim

COPY --chown=nginx:nginx --from=builder /app/build/web /usr/share/nginx/html
COPY --chown=nginx:nginx docker/nginx.conf.template /etc/nginx/templates/default.conf.template
COPY --chown=nginx:nginx docker/diapason-config.js.template /etc/nginx/templates/diapason-config.js.template

# Server preset injected into diapason-config.js at container start.
# SERVER_TYPE: jellyfin | subsonic | navidrome | plex. SERVER_LOCK: true to forbid other servers.
ENV SERVER_NAME="" SERVER_TYPE="" SERVER_URL="" SERVER_LOCK="false"
# Only substitute our own variables (nginx's $uri etc. must stay as is).
ENV NGINX_ENVSUBST_FILTER="^SERVER_"

EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
