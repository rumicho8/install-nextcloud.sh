#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Nextcloud automatic installation script
# Debian 13 (trixie)
# Nginx + MariaDB + PHP 8.4 + Redis + APCu
# ============================================================

# -----------------------------
# Basic configuration
# -----------------------------
NEXTCLOUD_DIR="/var/www/nextcloud"
NGINX_CONF="/etc/nginx/sites-available/nextcloud"
NGINX_LINK="/etc/nginx/sites-enabled/nextcloud"

PHP_VERSION="8.4"
PHP_FPM_SOCKET="/run/php/php8.4-fpm.sock"

# -----------------------------
# Root check
# -----------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 运行此脚本。"
    echo "例如：sudo bash install-nextcloud.sh"
    exit 1
fi

# -----------------------------
# OS check
# -----------------------------
if [[ ! -f /etc/os-release ]]; then
    echo "无法检测操作系统。"
    exit 1
fi

source /etc/os-release

if [[ "${ID}" != "debian" || "${VERSION_ID}" != "13" ]]; then
    echo "此脚本针对 Debian 13 编写。"
    echo "当前系统：${PRETTY_NAME}"
    exit 1
fi

echo
echo "============================================================"
echo " Nextcloud 自动安装程序"
echo " Debian 13 + Nginx + MariaDB + PHP 8.4 + Redis"
echo "============================================================"
echo

# -----------------------------
# Collect user information
# -----------------------------
read -rp "请输入 Nextcloud 访问地址/IP，例如 103.7.135.170: " SERVER_IP

if [[ -z "${SERVER_IP}" ]]; then
    echo "访问地址不能为空。"
    exit 1
fi

echo
echo "请输入 MariaDB 的 Nextcloud 数据库密码。"
echo "建议使用至少 16 位复杂密码。"
read -rsp "数据库密码: " DB_PASSWORD
echo

if [[ -z "${DB_PASSWORD}" ]]; then
    echo "数据库密码不能为空。"
    exit 1
fi

echo
echo "设置 Nextcloud 管理员账号。"
read -rp "管理员用户名 [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"

read -rsp "管理员密码: " ADMIN_PASSWORD
echo

if [[ -z "${ADMIN_PASSWORD}" ]]; then
    echo "管理员密码不能为空。"
    exit 1
fi

echo
echo "============================================================"
echo "安装参数："
echo "访问地址：${SERVER_IP}"
echo "数据库：nextcloud"
echo "数据库用户：nextcloud"
echo "管理员：${ADMIN_USER}"
echo "============================================================"
echo

read -rp "确认开始安装？[y/N]: " CONFIRM

if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    echo "已取消。"
    exit 0
fi

# -----------------------------
# Update system
# -----------------------------
echo
echo "[1/12] 更新软件源..."
apt update

# -----------------------------
# Install packages
# -----------------------------
echo
echo "[2/12] 安装 Nginx / MariaDB / PHP / Redis..."

apt install -y \
    nginx \
    mariadb-server \
    wget \
    unzip \
    bzip2 \
    curl \
    redis-server \
    imagemagick \
    php8.4-fpm \
    php8.4-mysql \
    php8.4-xml \
    php8.4-mbstring \
    php8.4-curl \
    php8.4-zip \
    php8.4-gd \
    php8.4-intl \
    php8.4-bcmath \
    php8.4-gmp \
    php8.4-apcu \
    php8.4-redis \
    php8.4-imagick

# -----------------------------
# Enable services
# -----------------------------
echo
echo "[3/12] 启动服务..."

systemctl enable --now nginx
systemctl enable --now mariadb
systemctl enable --now php8.4-fpm
systemctl enable --now redis-server

# -----------------------------
# PHP configuration
# -----------------------------
echo
echo "[4/12] 配置 PHP..."

PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
PHP_POOL="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"

# Use sed safely
sed -i 's/^[;[:space:]]*memory_limit[[:space:]]*=.*/memory_limit = 512M/' "${PHP_INI}"
sed -i 's/^[;[:space:]]*upload_max_filesize[[:space:]]*=.*/upload_max_filesize = 10G/' "${PHP_INI}"
sed -i 's/^[;[:space:]]*post_max_size[[:space:]]*=.*/post_max_size = 10G/' "${PHP_INI}"
sed -i 's/^[;[:space:]]*max_execution_time[[:space:]]*=.*/max_execution_time = 3600/' "${PHP_INI}"
sed -i 's/^[;[:space:]]*max_input_time[[:space:]]*=.*/max_input_time = 3600/' "${PHP_INI}"

# output_buffering
if grep -qE '^[;[:space:]]*output_buffering[[:space:]]*=' "${PHP_INI}"; then
    sed -i 's/^[;[:space:]]*output_buffering[[:space:]]*=.*/output_buffering = 0/' "${PHP_INI}"
else
    echo "output_buffering = 0" >> "${PHP_INI}"
fi

# PHP-FPM clear_env
if grep -qE '^[;[:space:]]*clear_env[[:space:]]*=' "${PHP_POOL}"; then
    sed -i 's/^[;[:space:]]*clear_env[[:space:]]*=.*/clear_env = no/' "${PHP_POOL}"
else
    echo "clear_env = no" >> "${PHP_POOL}"
fi

# PHP admin values
cat >> "${PHP_POOL}" <<'EOF'

; Nextcloud performance settings
php_admin_value[upload_max_filesize] = 10G
php_admin_value[post_max_size] = 10G
php_admin_value[memory_limit] = 512M
php_admin_value[max_execution_time] = 3600
php_admin_value[max_input_time] = 3600
EOF

# -----------------------------
# MariaDB
# -----------------------------
echo
echo "[5/12] 配置 MariaDB..."

systemctl restart mariadb

mariadb <<SQL
CREATE DATABASE IF NOT EXISTS nextcloud
CHARACTER SET utf8mb4
COLLATE utf8mb4_general_ci;

CREATE USER IF NOT EXISTS 'nextcloud'@'localhost'
IDENTIFIED BY '${DB_PASSWORD}';

ALTER USER 'nextcloud'@'localhost'
IDENTIFIED BY '${DB_PASSWORD}';

GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';

FLUSH PRIVILEGES;
SQL

# -----------------------------
# Download Nextcloud
# -----------------------------
echo
echo "[6/12] 下载 Nextcloud..."

if [[ -d "${NEXTCLOUD_DIR}" ]]; then
    echo "检测到 ${NEXTCLOUD_DIR} 已存在。"

    if [[ -f "${NEXTCLOUD_DIR}/occ" ]]; then
        echo "已有 Nextcloud 安装，停止操作以避免覆盖。"
        exit 1
    fi
fi

cd /var/www

rm -f latest.tar.bz2

wget -O latest.tar.bz2 \
    https://download.nextcloud.com/server/releases/latest.tar.bz2

tar -xjf latest.tar.bz2

rm -f latest.tar.bz2

# -----------------------------
# Permissions
# -----------------------------
echo
echo "[7/12] 设置 Nextcloud 权限..."

chown -R www-data:www-data "${NEXTCLOUD_DIR}"

find "${NEXTCLOUD_DIR}" -type d -exec chmod 750 {} \;
find "${NEXTCLOUD_DIR}" -type f -exec chmod 640 {} \;

# -----------------------------
# Install Nextcloud
# -----------------------------
echo
echo "[8/12] 安装 Nextcloud..."

sudo -u www-data php "${NEXTCLOUD_DIR}/occ" maintenance:install \
    --database="mysql" \
    --database-name="nextcloud" \
    --database-user="nextcloud" \
    --database-pass="${DB_PASSWORD}" \
    --database-host="localhost" \
    --admin-user="${ADMIN_USER}" \
    --admin-pass="${ADMIN_PASSWORD}"

# -----------------------------
# Nextcloud configuration
# -----------------------------
echo
echo "[9/12] 配置 Nextcloud..."

sudo -u www-data php "${NEXTCLOUD_DIR}/occ" config:system:set trusted_domains 0 \
    --value="${SERVER_IP}"

sudo -u www-data php "${NEXTCLOUD_DIR}/occ" config:system:set overwrite.cli.url \
    --value="http://${SERVER_IP}"

sudo -u www-data php "${NEXTCLOUD_DIR}/occ" config:system:set default_phone_region \
    --value="CN"

sudo -u www-data php "${NEXTCLOUD_DIR}/occ" config:system:set loglevel \
    --value="2" \
    --type=integer

# APCu
sudo -u www-data php "${NEXTCLOUD_DIR}/occ" config:system:set memcache.local \
    --value='\OC\Memcache\APCu'

# Redis distributed cache
sudo -u www-data php "${NEXTCLOUD_DIR}/occ" config:system:set memcache.distributed \
    --value='\OC\Memcache\Redis'

# Redis file locking
sudo -u www-data php "${NEXTCLOUD_DIR}/occ" config:system:set memcache.locking \
    --value='\OC\Memcache\Redis'

# Redis host
sudo -u www-data php "${NEXTCLOUD_DIR}/occ" config:system:set redis host \
    --value="127.0.0.1"

# Redis port
sudo -u www-data php "${NEXTCLOUD_DIR}/occ" config:system:set redis port \
    --value="6379" \
    --type=integer

# -----------------------------
# Nginx configuration
# -----------------------------
echo
echo "[10/12] 配置 Nginx..."

cat > "${NGINX_CONF}" <<'NGINX'
server {
    listen 80;
    listen [::]:80;

    server_name _;

    root /var/www/nextcloud;
    index index.php index.html /index.php$request_uri;

    client_max_body_size 10G;

    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    location = /.well-known/carddav {
        return 301 $scheme://$host/remote.php/dav;
    }

    location = /.well-known/caldav {
        return 301 $scheme://$host/remote.php/dav;
    }

    location /.well-known/acme-challenge {
        try_files $uri $uri/ =404;
    }

    location ^~ /.well-known {
        return 301 /index.php$request_uri;
    }

    location / {
        try_files $uri $uri/ /index.php$request_uri;
    }

    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/) {
        deny all;
    }

    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console) {
        deny all;
    }

    location ~ \.php(?:$|/) {
        rewrite ^/(?!index|remote|public|cron|core/ajax/update|status|ocs/v[12]|updater/.+|ocs-provider/.+|.+/richdocumentscode/proxy) /index.php$request_uri;

        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set $path_info $fastcgi_path_info;

        try_files $fastcgi_script_name =404;

        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $path_info;
        fastcgi_param HTTPS $https if_not_empty;

        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;

        fastcgi_pass unix:/run/php/php8.4-fpm.sock;

        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
        fastcgi_read_timeout 3600;
    }

    location ~ \.(?:css|js|mjs|svg|gif|ico|jpg|jpeg|png|webp|wasm|tflite|map|ogg|flac)$ {
        try_files $uri /index.php$request_uri;
        expires 6M;
        access_log off;
    }

    location ~ \.(?:otf|woff2?)$ {
        try_files $uri /index.php$request_uri;
        expires 7d;
        access_log off;
    }

    location ~ \.(?:mp4|webm|mkv|avi|mov)$ {
        try_files $uri /index.php$request_uri;
        access_log off;
    }
}
NGINX

rm -f /etc/nginx/sites-enabled/default

ln -sfn "${NGINX_CONF}" "${NGINX_LINK}"

nginx -t

# -----------------------------
# Cron
# -----------------------------
echo
echo "[11/12] 配置 Nextcloud Cron..."

CRON_LINE="*/5 * * * * php -f ${NEXTCLOUD_DIR}/cron.php"

(
    crontab -u www-data -l 2>/dev/null | grep -vF "${NEXTCLOUD_DIR}/cron.php" || true
    echo "${CRON_LINE}"
) | crontab -u www-data -

# -----------------------------
# Restart services
# -----------------------------
echo
echo "[12/12] 重启服务并执行检查..."

systemctl restart php8.4-fpm
systemctl restart redis-server
systemctl reload nginx

# Make sure services are enabled
systemctl enable nginx
systemctl enable mariadb
systemctl enable php8.4-fpm
systemctl enable redis-server

# -----------------------------
# Permissions again
# -----------------------------
chown -R www-data:www-data "${NEXTCLOUD_DIR}"

# -----------------------------
# Nextcloud check
# -----------------------------
echo
echo "============================================================"
echo " Nextcloud 安装检查"
echo "============================================================"

sudo -u www-data php "${NEXTCLOUD_DIR}/occ" status

echo
echo "APCu:"
sudo -u www-data php "${NEXTCLOUD_DIR}/occ" config:system:get memcache.local

echo
echo "Redis locking:"
sudo -u www-data php "${NEXTCLOUD_DIR}/occ" config:system:get memcache.locking

echo
echo "Redis:"
sudo -u www-data php "${NEXTCLOUD_DIR}/occ" config:system:get redis

echo
echo "Cron:"
crontab -u www-data -l | tail -n 5

echo
echo "Nginx:"
nginx -t

echo
echo "PHP-FPM:"
systemctl is-active php8.4-fpm

echo
echo "Redis:"
systemctl is-active redis-server

echo
echo "============================================================"
echo " 安装完成！"
echo "============================================================"
echo
echo "Nextcloud 地址："
echo "http://${SERVER_IP}/"
echo
echo "管理员账号：${ADMIN_USER}"
echo
echo "数据库：nextcloud"
echo "数据库用户：nextcloud"
echo
echo "请务必保存好数据库密码和管理员密码。"
echo
echo "HTTPS 尚未配置。"
echo "正式公网使用前，请配置 HTTPS。"
echo
