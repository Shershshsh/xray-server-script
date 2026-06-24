#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_FILE="/usr/local/etc/sing-box/config.json"
LINKS_FILE="/root/vpn_links.txt"
ENV_FILE="/usr/local/etc/sing-box/domain_info.env"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Скрипт нужно запускать от root.${NC}"
  exit 1
fi

function restart_singbox() {
    systemctl restart sing-box
    sleep 2
    if ! systemctl is-active --quiet sing-box; then
        echo -e "${RED}Ошибка: Sing-box не запустился!${NC}"
        journalctl -u sing-box -n 20 --no-pager
    else
        echo -e "${GREEN}Sing-box успешно работает.${NC}"
    fi
}

function install_dependencies() {
    echo -e "${CYAN}--- Установка Sing-box и зависимостей ---${NC}"
    apt update -y
    apt install -y curl jq uuid-runtime openssl ufw nginx certbot python3-certbot-nginx
    
    # Установка последнего Sing-box
    bash -c "$(curl -fsSL https://sing-box.app/deb-install.sh)"
    mkdir -p /usr/local/etc/sing-box
    echo -e "${GREEN}Sing-box установлен.${NC}"
}

function init_config() {
    read -p "Основной домен: " DOMAIN
    read -p "Email для SSL: " EMAIL
    
    # Генерация ключей
    KEYS=$(sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYS" | grep "PublicKey" | awk '{print $2}')
    SHORT_ID=$(openssl rand -hex 4)
    
    cat <<EOF > $CONFIG_FILE
{
  "dns": {
    "servers": [
      { "tag": "local", "address": "1.1.1.1", "detour": "direct" }
    ]
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "reality-inbound",
      "listen": "::",
      "listen_port": 8443,
      "users": [],
      "reality": {
        "enabled": true,
        "handshake": { "server": "www.microsoft.com", "server_port": 443 },
        "private_key": "$PRIVATE_KEY",
        "short_id": ["$SHORT_ID"]
      },
      "sniffing": { "enabled": true, "dest_override": ["http", "tls"] }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "default_domain_resolver": "local",
    "rules": [
      { "geosite": "category-ads", "action": "block" },
      { "geoip": "private", "action": "block" }
    ]
  }
}
EOF
    echo "$PUBLIC_KEY" > /usr/local/etc/sing-box/public_key.txt
    systemctl enable sing-box
    restart_singbox
}

function add_client() {
    read -p "Имя клиента: " NAME
    UUID=$(uuidgen)
    
    # Добавление клиента в JSON через jq
    jq --arg uuid "$UUID" --arg email "$NAME" \
    '.inbounds[0].users += [{"uuid": $uuid, "flow": "xtls-rprx-vision", "name": $email}]' \
    "$CONFIG_FILE" > /tmp/sb_tmp.json && mv /tmp/sb_tmp.json "$CONFIG_FILE"
    
    restart_singbox
    echo -e "${GREEN}Клиент $NAME добавлен.${NC}"
}

# Меню управления
while true; do
    echo -e "${CYAN}=== ULTIMATE SING-BOX MANAGER ===${NC}"
    echo "1. Установка"
    echo "2. Инициализация конфига (Sing-box 1.13+)"
    echo "3. Добавить клиента"
    echo "0. Выход"
    read -p "Выбор: " choice
    case $choice in
        1) install_dependencies ;;
        2) init_config ;;
        3) add_client ;;
        0) exit 0 ;;
    esac
done
