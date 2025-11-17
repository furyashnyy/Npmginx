#!/usr/bin/env bash
set -euo pipefail

DOMAIN="obscpsl.ru"
WWW_DOMAIN="www.${DOMAIN}"
WEB_ROOT="/var/www/${DOMAIN}/html"
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
NGINX_ENABLED_LINK="/etc/nginx/sites-enabled/${DOMAIN}"
INSTRUCTIONS_FILE="/root/${DOMAIN}_nginx_node_instructions.txt"
NODE_VERSION_MINIMUM=16
NODESOURCE_SETUP_SCRIPT="https://deb.nodesource.com/setup_18.x"

log() {
  local green="\033[32m"
  local reset="\033[0m"
  echo -e "${green}[INFO]${reset} $*"
}

warn() {
  local yellow="\033[33m"
  local reset="\033[0m"
  echo -e "${yellow}[WARN]${reset} $*" >&2
}

error_exit() {
  local red="\033[31m"
  local reset="\033[0m"
  echo -e "${red}[ERROR]${reset} $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error_exit "Этот скрипт необходимо запускать от пользователя root (используйте sudo)."
  fi
}

run_apt_update() {
  log "Обновление кеша пакетов APT..."
  apt-get update
}

install_packages() {
  local packages=("ca-certificates" "curl" "gnupg" "lsb-release" "nginx" "certbot" "python3-certbot-nginx")
  log "Установка/обновление пакетов: ${packages[*]}"
  apt-get install -y "${packages[@]}"
}

ensure_nginx_enabled() {
  log "Включение и запуск nginx..."
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx
}

ensure_node() {
  local needs_install=1
  if command -v node >/dev/null 2>&1; then
    local node_version
    node_version=$(node -v | sed 's/^v//')
    local node_major=${node_version%%.*}
    if [[ -n "${node_major}" ]] && (( node_major >= NODE_VERSION_MINIMUM )); then
      needs_install=0
      log "Node.js ${node_version} уже установлен и соответствует требованию >= ${NODE_VERSION_MINIMUM}."
    else
      warn "Текущая версия Node.js (${node_version}) меньше ${NODE_VERSION_MINIMUM}, будет установлена подходящая версия."
    fi
  fi

  if (( needs_install == 1 )); then
    log "Установка Node.js LTS (ветка 18.x) через NodeSource..."
    curl -fsSL "${NODESOURCE_SETUP_SCRIPT}" | bash -
    apt-get install -y nodejs
    log "Установлена версия Node.js $(node -v)."
  fi
}

setup_web_root() {
  log "Создание директории веб-корня ${WEB_ROOT}..."
  mkdir -p "${WEB_ROOT}"
  chown -R www-data:www-data "/var/www/${DOMAIN}"
  chmod -R 755 "/var/www/${DOMAIN}"

  if [[ ! -f "${WEB_ROOT}/index.html" ]]; then
    cat > "${WEB_ROOT}/index.html" <<EOF
<!doctype html>
<html lang="ru">
  <head>
    <meta charset="utf-8">
    <title>obscpsl.ru</title>
  </head>
  <body>
    <h1>obscpsl.ru успешно настроен</h1>
    <p>Замените содержимое этой страницы файлами вашего сайта.</p>
  </body>
</html>
EOF
    chown www-data:www-data "${WEB_ROOT}/index.html"
  fi
}

create_nginx_config() {
  log "Создание конфигурации nginx для домена ${DOMAIN}..."
  cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} ${WWW_DOMAIN};

    root ${WEB_ROOT};
    index index.html index.htm;

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log /var/log/nginx/${DOMAIN}.error.log;

    location / {
        try_files \$uri \$uri/ @node_dev_server;
    }

    location @node_dev_server {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }

    location ~* \.(?:css|js|jpg|jpeg|gif|png|svg|ico|woff2?)$ {
        try_files \$uri \$uri/ @node_dev_server;
        expires 7d;
        access_log off;
    }
}
EOF

  ln -sf "${NGINX_CONF}" "${NGINX_ENABLED_LINK}"
  if [[ -f /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  log "Проверка конфигурации nginx..."
  nginx -t
  systemctl reload nginx
}

obtain_certificate() {
  local email="${CERTBOT_EMAIL:-}"
  if [[ -z "${email}" ]]; then
    read -rp "Введите email для уведомлений Let's Encrypt: " email
  fi

  if [[ -z "${email}" ]]; then
    warn "Email не указан, пропускаем выдачу сертификата Let's Encrypt. Настройте сертификат вручную позже.";
    return
  fi

  log "Запрос и установка сертификата Let's Encrypt для ${DOMAIN}..."
  if certbot --nginx --agree-tos --email "${email}" --no-redirect --non-interactive -d "${DOMAIN}" -d "${WWW_DOMAIN}"; then
    log "Сертификат успешно установлен. HTTPS доступен без принудительного редиректа с HTTP."
  else
    warn "Не удалось автоматически получить сертификат. Проверьте DNS-настройки домена и повторите команду вручную:";
    warn "  certbot --nginx -d ${DOMAIN} -d ${WWW_DOMAIN}"
  fi
}

write_instructions() {
  log "Создание инструкции по запуску npm-проекта через nginx (${INSTRUCTIONS_FILE})..."
  cat > "${INSTRUCTIONS_FILE}" <<EOF
# Инструкция по запуску сайта obscpsl.ru через nginx

## 1. Расположение файлов сайта
- Корневой каталог для статических файлов: ${WEB_ROOT}
- Права доступа: владельцем должен быть пользователь, под которым работает приложение (по умолчанию www-data).

## 2. Запуск приложения, которое ранее стартовало командой \`npm run dev\`
1. Скопируйте исходный код проекта в отдельную директорию, например \`/var/www/${DOMAIN}/app\`.
2. Установите зависимости:
   ```bash
   cd /var/www/${DOMAIN}/app
   npm install
   ```
3. Убедитесь, что dev-сервер слушает только локальный адрес (например, \`127.0.0.1\`) и порт \`3000\`. Многие фреймворки поддерживают параметры \`--host 127.0.0.1 --port 3000\`.
   ```bash
   npm run dev -- --host 127.0.0.1 --port 3000
   ```
4. Для автоматического запуска создайте systemd-сервис:
   ```bash
   sudo tee /etc/systemd/system/obscpsl-dev.service <<'SERVICE'
   [Unit]
   Description=obscpsl.ru frontend dev server
   After=network.target

   [Service]
   Type=simple
   WorkingDirectory=/var/www/${DOMAIN}/app
   ExecStart=/usr/bin/npm run dev -- --host 127.0.0.1 --port 3000
   Restart=always
   Environment=NODE_ENV=development
   User=www-data
   Group=www-data

   [Install]
   WantedBy=multi-user.target
   SERVICE

   sudo systemctl daemon-reload
   sudo systemctl enable --now obscpsl-dev.service
   ```
5. Проверьте, что сервис запущен и слушает порт 3000 локально:
   ```bash
   systemctl status obscpsl-dev.service
   ss -tulpn | grep 3000
   ```

## 3. Работа только через HTTP(S)
- nginx проксирует внешний HTTP-трафик на локальный порт 3000, приложение напрямую из интернета недоступно.
- Если сертификат получен, сайт будет доступен по HTTPS без обязательного редиректа с HTTP, т.е. HTTP также остаётся доступным.

## 4. Обновление сертификатов
- Автообновление сертификатов Let's Encrypt настроено systemd-таймером (\`certbot.timer\`).
- Для принудительного обновления используйте: \`certbot renew --dry-run\`.

## 5. Полезные команды
- Перезагрузка nginx: \`systemctl reload nginx\`
- Проверка конфигурации nginx: \`nginx -t\`
- Просмотр логов приложения: \`journalctl -u obscpsl-dev.service -f\`

EOF
  chmod 600 "${INSTRUCTIONS_FILE}"
}

print_summary() {
  echo
  log "Настройка завершена."
  echo "Директория для файлов сайта: ${WEB_ROOT}"
  if [[ -f "${INSTRUCTIONS_FILE}" ]]; then
    echo "Инструкция по работе с npm-проектом сохранена в: ${INSTRUCTIONS_FILE}"
  fi
  echo
}

main() {
  require_root
  run_apt_update
  install_packages
  ensure_nginx_enabled
  ensure_node
  setup_web_root
  create_nginx_config
  obtain_certificate
  write_instructions
  print_summary
}

main "$@"
