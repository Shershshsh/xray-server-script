#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

CONFIG_FILE="/usr/local/etc/xray/config.json"
LINKS_FILE="/root/vpn_links.txt"
ENV_FILE="/usr/local/etc/xray/domain_info.env"

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Скрипт нужно запускать от root (sudo bash vpn_manager.sh)${NC}"
  exit 1
fi

function restart_xray() {
    systemctl restart xray
    sleep 2
    if ! systemctl is-active --quiet xray; then
        echo -e "${RED}Ошибка: Xray не запустился! Последние 10 строк лога:${NC}"
        journalctl -u xray -n 10 --no-pager
    else
        echo -e "${GREEN}Xray успешно работает.${NC}"
        # Выдаем права на сокеты для Nginx
        chmod 777 /dev/shm/xray-*.sock 2>/dev/null || true
    fi
}

function optimize_os() {
    echo -e "${CYAN}--- Оптимизация ядра Linux (BBR, IPv6, Лимиты) ---${NC}"
    
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 > /dev/null
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1 > /dev/null
    
    cat <<EOF > /etc/sysctl.d/99-vpn-optimize.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
fs.file-max = 1000000
EOF
    sysctl --system > /dev/null

    cat <<EOF > /etc/security/limits.d/xray.conf
* soft nofile 1000000
* hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
EOF

    echo -e "${GREEN}Оптимизация завершена.${NC}"
}

function install_dependencies() {
    if [ -f "$ENV_FILE" ]; then
        echo -e "${YELLOW}Инфраструктура уже установлена. Повторная установка перезапишет домены. Продолжить? [y/N]${NC}"
        read -r CONFIRM
        if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
            return
        fi
    fi

    echo -e "${YELLOW}ВНИМАНИЕ! Перед продолжением убедитесь, что ваши домены указывают на IP этого сервера.${NC}"
    read -p "Введите основной домен (оранжевое облако, для SplitHTTP/gRPC): " DOMAIN
    read -p "Введите прямой домен (серое облако, для Reality): " DIRECT_DOMAIN
    read -p "Введите email для Let's Encrypt: " EMAIL

    if [ -z "$DOMAIN" ] || [ -z "$DIRECT_DOMAIN" ] || [ -z "$EMAIL" ]; then
        echo -e "${RED}Ошибка: Домены и email обязательны для заполнения.${NC}"
        return
    fi

    echo -e "${CYAN}--- Установка пакетов ---${NC}"
    apt update -y > /dev/null
    apt install -y curl jq uuid-runtime openssl ufw fail2ban nginx certbot python3-certbot-nginx > /dev/null
    
    echo -e "${CYAN}--- Настройка UFW ---${NC}"
    # Динамически определяем текущий порт SSH, чтобы не отрезать доступ
    SSH_PORT=$(ss -tlnp | awk '/sshd/ {print $4}' | rev | cut -d: -f1 | rev | sort -u | head -n 1)
    if [ -z "$SSH_PORT" ]; then SSH_PORT=22; fi

    ufw --force reset > /dev/null
    ufw default deny incoming > /dev/null
    ufw default allow outgoing > /dev/null
    ufw allow $SSH_PORT/tcp > /dev/null
    ufw allow 80/tcp > /dev/null
    ufw allow 443/tcp > /dev/null
    ufw allow 8443/tcp > /dev/null
    ufw --force enable > /dev/null
    echo -e "${GREEN}UFW настроен (SSH порт: $SSH_PORT).${NC}"

    echo -e "${CYAN}--- Настройка Fail2Ban ---${NC}"
    cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 5
findtime = 600
bantime = 3600
EOF
    systemctl restart fail2ban
    systemctl enable fail2ban

    echo -e "${CYAN}--- Настройка Nginx и получение SSL ---${NC}"
    systemctl stop nginx
    if certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m $EMAIL; then
        echo -e "${GREEN}Сертификат получен.${NC}"
    else
        echo -e "${RED}Ошибка получения сертификата! Проверьте DNS и попробуйте снова.${NC}"
        systemctl start nginx
        return
    fi

    # Сайт заглушка
    mkdir -p /var/www/html
    cat <<EOF > /var/www/html/index.html
<!DOCTYPE html>
<html>
<head><title>Welcome</title></head>
<body>
    <h1>Service temporarily unavailable</h1>
    <p>Please try again later.</p>
</body>
</html>
EOF

    # Конфиг Nginx
    rm -f /etc/nginx/sites-enabled/default
    cat <<EOF > /etc/nginx/conf.d/xray.conf
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    server_tokens off;

    location / {
        root /var/www/html;
        index index.html;
        try_files \$uri \$uri/ =404;
    }

    location /splithttp/ {
        proxy_pass http://unix:/dev/shm/xray-splithttp.sock;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_request_buffering off;
    }

    location /grpc/ {
        grpc_pass unix:/dev/shm/xray-grpc.sock;
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_read_timeout 1d;
        grpc_send_timeout 1d;
    }
}
EOF
    systemctl start nginx
    if nginx -t; then
        systemctl reload nginx
        echo -e "${GREEN}Nginx успешно перезагружен.${NC}"
    else
        echo -e "${RED}Ошибка в конфиге Nginx! Проверьте /etc/nginx/conf.d/xray.conf${NC}"
    fi
    systemctl enable nginx
    
    echo -e "${CYAN}--- Установка чистого Xray Core ---${NC}"
    # Убрали > /dev/null чтобы в случае ошибки скрипт XTLS не молчал, а показал проблему
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    # Скачиваем расширенные базы данных маршрутизации
    echo -e "${CYAN}--- Загрузка расширенных баз маршрутизации (Loyalsoldier) ---${NC}"
    curl -L -o /usr/local/share/xray/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
    curl -L -o /usr/local/share/xray/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
    echo -e "${GREEN}Базы данных успешно загружены.${NC}"

    # Сохраняем переменные для дальнейшего использования
    mkdir -p /usr/local/etc/xray
    echo "DOMAIN=$DOMAIN" > $ENV_FILE
    echo "DIRECT_DOMAIN=$DIRECT_DOMAIN" >> $ENV_FILE
    
    echo -e "${GREEN}Инфраструктура установлена.${NC}"
}

function init_reality_config() {
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}Ошибка: сначала выполните пункт 1 (установка инфраструктуры).${NC}"
        return
    fi
    
    echo -e "${CYAN}--- Создание конфига Xray (Reality, SplitHTTP, gRPC) ---${NC}"
    
    # Динамически ищем бинарник Xray (вдруг он от 3x-ui или в другой папке)
    XRAY_CMD=""
    for p in /usr/local/bin/xray /usr/bin/xray /opt/xray/xray /usr/local/x-ui/bin/xray-linux-amd64; do
        if [ -x "$p" ]; then
            XRAY_CMD="$p"
            break
        fi
    done

    # Если не нашли по жестким путям, пробуем через команду системы
    if [ -z "$XRAY_CMD" ]; then
        XRAY_CMD=$(command -v xray)
    fi

    if [ -z "$XRAY_CMD" ]; then
        echo -e "${RED}Ошибка: Не удалось найти исполняемый файл Xray в системе. Выполните пункт 1.${NC}"
        return
    fi

    # Генерируем ключи с защитой от пустых строк и мусора
    KEYS=$($XRAY_CMD x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private key" | awk '{print $3}' | tr -d '\r' | tr -d '\n')
    PUBLIC_KEY=$(echo "$KEYS" | grep -i "Public key" | awk '{print $3}' | tr -d '\r' | tr -d '\n')
    SHORT_ID=$(openssl rand -hex 4)

    # Защита: если ключи не сгенерировались
    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        echo -e "${RED}Критическая ошибка: Не удалось сгенерировать ключи Reality.${NC}"
        echo -e "${YELLOW}Использован бинарник: $XRAY_CMD${NC}"
        echo -e "${YELLOW}Ответ системы: $KEYS${NC}"
        return
    fi

    mkdir -p /var/log/xray
    
    source $ENV_FILE

    cat <<EOF > $CONFIG_FILE
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": 8443,
      "protocol": "vless",
      "tag": "reality-inbound",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": ["www.microsoft.com"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      }
    },
    {
      "listen": "/dev/shm/xray-splithttp.sock",
      "protocol": "vless",
      "tag": "splithttp-inbound",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "splithttp",
        "splithttpSettings": {
          "path": "/splithttp/",
          "host": "$DOMAIN"
        }
      }
    },
    {
      "listen": "/dev/shm/xray-grpc.sock",
      "protocol": "vless",
      "tag": "grpc-inbound",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {
          "serviceName": "grpc"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "UseIP",
    "rules": [
      {
        "type": "field",
        "domain": [
          "geosite:category-ads"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": ["geoip:ru"],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

    echo "$PUBLIC_KEY" > /usr/local/etc/xray/public_key.txt
    chmod 600 /usr/local/etc/xray/public_key.txt
    
    restart_xray
    echo -e "${GREEN}Базовый конфиг создан. Перейдите к добавлению клиентов.${NC}"
}

function add_client() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Конфиг не найден. Сначала выполните инициализацию (Пункт 2).${NC}"
        return
    fi

    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}Ошибка: сначала выполните пункт 1 (установка инфраструктуры).${NC}"
        return
    fi
    source $ENV_FILE

    read -p "Введите имя нового клиента (например, user1): " CLIENT_NAME
    if [ -z "$CLIENT_NAME" ]; then
        echo -e "${RED}Имя не может быть пустым.${NC}"
        return
    fi

    # Проверка дубликата
    if jq -e --arg email "$CLIENT_NAME" '.inbounds[0].settings.clients[] | select(.email == $email)' "$CONFIG_FILE" > /dev/null; then
        echo -e "${RED}Ошибка: Клиент с именем '$CLIENT_NAME' уже существует!${NC}"
        return
    fi

    UUID=$(uuidgen)
    
    # ПРАВКА: Безопасное добавление клиента (с бэкапом)
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    if jq --arg uuid "$UUID" --arg email "$CLIENT_NAME" \
    '.inbounds[0].settings.clients += [{"id": $uuid, "flow": "xtls-rprx-vision", "email": $email}] |
     .inbounds[1].settings.clients += [{"id": $uuid, "email": $email}] |
     .inbounds[2].settings.clients += [{"id": $uuid, "email": $email}]' \
    "$CONFIG_FILE" > /tmp/xray_tmp.json && [ -s /tmp/xray_tmp.json ]; then
        mv /tmp/xray_tmp.json "$CONFIG_FILE"
    else
        echo -e "${RED}Критическая ошибка при записи JSON! Восстанавливаем конфиг из бэкапа.${NC}"
        mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
        return
    fi

    restart_xray

    # Сборка ссылок
    PUB_KEY=$(cat /usr/local/etc/xray/public_key.txt)
    SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' $CONFIG_FILE)
    
    LINK_REALITY="vless://${UUID}@${DIRECT_DOMAIN}:8443?type=tcp&security=reality&pbk=${PUB_KEY}&fp=chrome&sni=www.microsoft.com&sid=${SHORT_ID}&flow=xtls-rprx-vision#Reality-${CLIENT_NAME}"
    LINK_SPLITHTTP="vless://${UUID}@${DOMAIN}:443?type=splithttp&security=tls&sni=${DOMAIN}&host=${DOMAIN}&path=%2Fsplithttp%2F&fp=chrome#SplitHTTP-${CLIENT_NAME}"
    LINK_GRPC="vless://${UUID}@${DOMAIN}:443?type=grpc&security=tls&sni=${DOMAIN}&host=${DOMAIN}&serviceName=grpc&fp=chrome#gRPC-${CLIENT_NAME}"

    echo -e "\n=== Клиент: $CLIENT_NAME ===" >> $LINKS_FILE
    echo "$LINK_REALITY" >> $LINKS_FILE
    echo "$LINK_SPLITHTTP" >> $LINKS_FILE
    echo "$LINK_GRPC" >> $LINKS_FILE
    chmod 600 $LINKS_FILE
    
    echo -e "\n${GREEN}Клиент $CLIENT_NAME успешно добавлен!${NC}"
    echo -e "${YELLOW}Скопируйте эти ссылки:${NC}"
    echo -e "$LINK_REALITY"
    echo -e "$LINK_SPLITHTTP"
    echo -e "$LINK_GRPC\n"
}

function list_clients() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Конфиг не найден.${NC}"
        return
    fi
    echo -e "${CYAN}--- Текущие клиенты в Xray ---${NC}"
    jq -r '.inbounds[0].settings.clients[] | "Имя (email): \(.email) | UUID: \(.id)"' "$CONFIG_FILE"
    echo ""
}

function delete_client() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Конфиг не найден.${NC}"
        return
    fi

    list_clients

    read -p "Введите имя (email) клиента для удаления: " DEL_NAME
    if [ -z "$DEL_NAME" ]; then
        return
    fi

    if ! jq -e --arg email "$DEL_NAME" '.inbounds[0].settings.clients[] | select(.email == $email)' "$CONFIG_FILE" > /dev/null; then
        echo -e "${RED}Ошибка: Клиент '$DEL_NAME' не найден.${NC}"
        return
    fi

    # ПРАВКА: Безопасное удаление клиента (с бэкапом)
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    if jq --arg email "$DEL_NAME" \
    '.inbounds[0].settings.clients |= map(select(.email != $email)) |
     .inbounds[1].settings.clients |= map(select(.email != $email)) |
     .inbounds[2].settings.clients |= map(select(.email != $email))' \
    "$CONFIG_FILE" > /tmp/xray_tmp.json && [ -s /tmp/xray_tmp.json ]; then
        mv /tmp/xray_tmp.json "$CONFIG_FILE"
    else
        echo -e "${RED}Критическая ошибка при записи JSON! Восстанавливаем конфиг из бэкапа.${NC}"
        mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
        return
    fi
    
    # Удаляем его ссылки из сохраненного файла
    if [ -f "$LINKS_FILE" ]; then
        sed -i "/=== Клиент: ${DEL_NAME} ===/d" "$LINKS_FILE"
        sed -i "/Reality-${DEL_NAME}/d" "$LINKS_FILE"
        sed -i "/SplitHTTP-${DEL_NAME}/d" "$LINKS_FILE"
        sed -i "/gRPC-${DEL_NAME}/d" "$LINKS_FILE"
    fi

    restart_xray
    echo -e "${GREEN}Клиент $DEL_NAME успешно удален.${NC}"
}

function show_links() {
    if [ ! -f "$LINKS_FILE" ]; then
        echo -e "${RED}Нет сохраненных ссылок.${NC}"
        return
    fi
    echo -e "${CYAN}--- Все сгенерированные ссылки ---${NC}"
    cat $LINKS_FILE
    echo ""
}

function check_status() {
    echo -e "${CYAN}--- Диагностика системы ---${NC}"
    
    if systemctl is-active --quiet nginx; then
        echo -e "Nginx: ${GREEN}Работает${NC}"
    else
        echo -e "Nginx: ${RED}Не работает${NC}"
    fi

    if systemctl is-active --quiet xray; then
        echo -e "Xray: ${GREEN}Работает${NC}"
    else
        echo -e "Xray: ${RED}Не работает${NC}"
    fi

    if [ -S "/dev/shm/xray-splithttp.sock" ]; then
        echo -e "Сокет SplitHTTP: ${GREEN}Существует${NC}"
    else
        echo -e "Сокет SplitHTTP: ${RED}Не найден${NC}"
    fi

    if [ -S "/dev/shm/xray-grpc.sock" ]; then
        echo -e "Сокет gRPC: ${GREEN}Существует${NC}"
    else
        echo -e "Сокет gRPC: ${RED}Не найден${NC}"
    fi

    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}Ошибка: сначала выполните пункт 1 (установка инфраструктуры).${NC}"
        return
    fi
    source $ENV_FILE
    
    echo -e "Сайт-заглушка: HTTP-код $(curl -o /dev/null -s -w "%{http_code}\n" https://$DOMAIN)"
    echo ""
}

function update_xray() {
    echo -e "${CYAN}--- Обновление Xray Core и баз маршрутизации ---${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    curl -L -o /usr/local/share/xray/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
    curl -L -o /usr/local/share/xray/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat

    restart_xray
    
    XRAY_CMD=""
    for p in /usr/local/bin/xray /usr/bin/xray /opt/xray/xray /usr/local/x-ui/bin/xray-linux-amd64; do
        if [ -x "$p" ]; then XRAY_CMD="$p"; break; fi
    done
    [ -z "$XRAY_CMD" ] && XRAY_CMD=$(command -v xray)
    
    echo -e "${GREEN}Текущая версия Xray:${NC}"
    $XRAY_CMD version
    echo ""
}

# Главное меню
while true; do
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${YELLOW} ULTIMATE XRAY MANAGER (CDN + Reality)   ${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo "1.  🚀 Установка инфраструктуры (Nginx, Certbot, Xray) и оптимизация"
    echo "2.  🛡️ Инициализация бронебойного конфига Xray"
    echo "3.  👤 Добавить нового клиента (получить 3 ссылки)"
    echo "4.  📋 Показать список клиентов"
    echo "5.  ❌ Удалить клиента"
    echo "6.  🔗 Показать сохраненные ссылки"
    echo "7.  🔄 Перезапустить Xray"
    echo "8.  ⬆️ Обновить Xray до последней версии"
    echo "9.  🔍 Проверить статус системы (Диагностика)"
    echo "10. 📄 Посмотреть логи Xray (режим реального времени)"
    echo "0.  Выход"
    echo -e "${CYAN}=========================================${NC}"
    read -p "Выберите действие [0-10]: " choice

    case $choice in
        1)
            install_dependencies
            optimize_os
            ;;
        2)
            init_reality_config
            ;;
        3)
            add_client
            ;;
        4)
            list_clients
            ;;
        5)
            delete_client
            ;;
        6)
            show_links
            ;;
        7)
            restart_xray
            ;;
        8)
            update_xray
            ;;
        9)
            check_status
            ;;
        10)
            echo -e "${YELLOW}Нажмите Ctrl+C для выхода из логов.${NC}"
            if [ -f "/var/log/xray/error.log" ]; then
                tail -f /var/log/xray/error.log /var/log/xray/access.log
            else
                journalctl -u xray -f
            fi
            ;;
        0)
            echo "Выход..."
            exit 0
            ;;
        *)
            echo -e "${RED}Неверный выбор.${NC}"
            ;;
    esac
done
