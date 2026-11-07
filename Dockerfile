# Сервер Island для бесплатного хостинга (Render): Godot запускается без экрана.
FROM debian:bookworm-slim

ARG GODOT_VERSION=4.7.1

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip libfontconfig1 libxcursor1 libxinerama1 libxrandr2 libxi6 libgl1 \
    && rm -rf /var/lib/apt/lists/*

RUN F="Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" \
    && (curl -fsSL -o /tmp/godot.zip "https://github.com/godotengine/godot-builds/releases/download/${GODOT_VERSION}-stable/${F}" \
        || curl -fsSL -o /tmp/godot.zip "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/${F}") \
    && unzip -q /tmp/godot.zip -d /tmp/godot \
    && find /tmp/godot -maxdepth 1 -type f -name 'Godot_v*' -exec mv {} /usr/local/bin/godot \; \
    && chmod +x /usr/local/bin/godot \
    && rm -rf /tmp/godot /tmp/godot.zip

WORKDIR /app
COPY . /app

# Импорт ресурсов проекта (создаёт папку .godot). Предупреждения не страшны.
RUN timeout 120 godot --headless --path /app --import || true

# Порт сервер берёт из переменной PORT, которую задаёт Render.
CMD ["godot", "--headless", "--path", "/app", "--", "--server"]
