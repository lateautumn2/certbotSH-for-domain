#!/bin/bash
# ============================================
# certbot.sh — SSL 证书一站式管理脚本
# 功能：申请 / 续签 / 同步证书
# 支持：Standalone / Webroot / Manual DNS / Cloudflare DNS
# ============================================

set -euo pipefail

# ---------- 定时任务时间配置 ----------
SYNC_CRON_SCHEDULE="30 4 * * *"   # 每天 4:30 同步证书文件
RENEW_CRON_SCHEDULE="0 3 * * *"   # 每天 3:00 检查续签

# ---------- 函数：同步所有已颁发证书到 /root/cert/ ----------
sync_certificates() {
    local sync_count=0
    local live_dir="/etc/letsencrypt/live"

    if [[ ! -d "$live_dir" ]]; then
        echo "⚠ 目录 $live_dir 不存在，没有证书可同步"
        return 1
    fi

    for domain_dir in "$live_dir"/*/; do
        [[ -d "$domain_dir" ]] || continue

        domain=$(basename "$domain_dir")
        local src_path="$live_dir/$domain"
        local dst_path="/root/cert/$domain/"

        mkdir -p "$dst_path"

        local f_full="$src_path/fullchain.pem"
        local f_priv="$src_path/privkey.pem"

        if [[ -f "$f_full" && -f "$f_priv" ]]; then
            cp -p "$f_full" "${dst_path}${domain}_fullchain.pem"
            cp -p "$f_priv" "${dst_path}${domain}_privkey.pem"
            echo "✔ 已同步 $domain → ${dst_path}"
            ((sync_count++))
        else
            echo "⚠ $domain 证书文件不完整，跳过"
        fi
    done

    if [[ $sync_count -eq 0 ]]; then
        echo "⚠ 没有找到可同步的证书"
    else
        echo "✔ 共同步 $sync_count 个域名的证书"
    fi
}

# ---------- 函数：安装 certbot 及必要依赖 ----------
install_deps() {
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq certbot 2>/dev/null || {
        echo "✗ 安装 certbot 失败，请检查网络或手动安装"
        exit 1
    }
}

# ---------- 函数：设置 crontab（自动去重） ----------
setup_crontab() {
    local script_path
    script_path=$(realpath "$0")
    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null || true)

    local renew_line="$RENEW_CRON_SCHEDULE /usr/bin/certbot renew --quiet"
    local sync_line="$SYNC_CRON_SCHEDULE $script_path 1"

    local new_crontab="$current_crontab"
    local changed=false

    if ! echo "$current_crontab" | grep -Fqs -- "$renew_line"; then
        new_crontab="${new_crontab}
${renew_line}"
        changed=true
    fi

    if ! echo "$current_crontab" | grep -Fqs -- "$sync_line"; then
        new_crontab="${new_crontab}
${sync_line}"
        changed=true
    fi

    if $changed; then
        # 去除开头的空行
        new_crontab=$(echo "$new_crontab" | sed '/^$/d')
        echo "$new_crontab" | crontab -
        echo "✔ crontab 已更新"
    else
        echo "ℹ crontab 无需更新"
    fi

    echo "   续签: $RENEW_CRON_SCHEDULE"
    echo "   同步: $SYNC_CRON_SCHEDULE"
}

# ---------- 函数：Cloudflare 配置 ----------
setup_cloudflare_creds() {
    local config_path="/etc/letsencrypt/cloudflare.ini"

    echo ""
    echo "Cloudflare 认证方式:"
    echo "  1) API Token（推荐，更安全的粒度权限）"
    echo "  2) Global API Key（旧版，使用邮箱+密钥）"
    read -p "请选择 (1-2): " cf_auth_type

    case "$cf_auth_type" in
        1)
            read -p "Cloudflare API Token: " cf_token
            cat > "$config_path" <<EOF
dns_cloudflare_api_token = $cf_token
EOF
            ;;
        2)
            read -p "Cloudflare Email: " cf_email
            read -p "Cloudflare API Key: " cf_key
            cat > "$config_path" <<EOF
dns_cloudflare_email = $cf_email
dns_cloudflare_api_key = $cf_key
EOF
            ;;
        *)
            echo "✗ 无效选择，使用 API Token"
            read -p "Cloudflare API Token: " cf_token
            cat > "$config_path" <<EOF
dns_cloudflare_api_token = $cf_token
EOF
            ;;
    esac

    chmod 600 "$config_path"
    echo "$config_path"
}

# ---------- 函数：显示帮助 ----------
show_help() {
    echo "用法: $0 [模式]"
    echo ""
    echo "模式:"
    echo "  1    同步证书（将 /etc/letsencrypt/live/ 下的证书复制到 /root/cert/）"
    echo "  2    申请新证书（默认）"
    echo ""
    echo "示例:"
    echo "  $0      申请新证书"
    echo "  $0 1    同步证书"
}

# ============================================
# 主逻辑
# ============================================

# 处理 --help
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help
    exit 0
fi

sh_type=${1:-2}

# ---- 模式 1：同步证书 ----
if [[ "$sh_type" == "1" ]]; then
    sync_certificates
    exit 0
fi

# ---- 模式 2：申请新证书 ----
install_deps

echo ""
echo "=========================================="
echo " 选择验证方式"
echo "=========================================="
echo "  1) HTTP-01 (Standalone) — 监听 80 端口验证"
echo "  2) HTTP-01 (Webroot)    — 写入网站目录验证"
echo "  3) DNS-01 (Manual)      — 手动添加 DNS TXT 记录"
echo "  4) DNS-01 (Cloudflare)  — Cloudflare API 自动"
echo "=========================================="
read -p "请输入 (1-4): " auth_method

# 校验输入
case "$auth_method" in 1|2|3|4) ;; *)
    echo "✗ 无效选择"; exit 1
esac

# 输入域名
read -p "输入域名 (如 example.com): " domain
[[ -n "$domain" ]] || { echo "✗ 域名不能为空"; exit 1; }

# 构建 certbot 域名参数
case "$auth_method" in
    1|2)
        # HTTP-01 不支持泛域名
        cert_domains="-d $domain"
        echo "ℹ HTTP-01 不支持泛域名，仅为 $domain 申请"
        ;;
    3|4)
        read -p "是否申请泛域名证书? (yes/no): " wildcard_yn
        if [[ "$wildcard_yn" == "yes" || "$wildcard_yn" == "y" ]]; then
            cert_domains="-d $domain -d *.$domain"
        else
            cert_domains="-d $domain"
        fi
        ;;
esac

# ---------- 按验证方式执行申请 ----------
case "$auth_method" in
    1)
        echo "⏳ 使用 Standalone 方式申请 $domain ..."
        certbot certonly --standalone $cert_domains \
            --non-interactive --agree-tos --register-unsafely-without-email \
            || { echo "✗ 申请失败"; exit 1; }
        ;;

    2)
        read -p "输入网站根目录 (如 /var/www/html): " webroot_path
        [[ -d "$webroot_path" ]] || { echo "✗ 目录不存在"; exit 1; }
        echo "⏳ 使用 Webroot 方式申请 $domain ..."
        certbot certonly --webroot -w "$webroot_path" $cert_domains \
            --non-interactive --agree-tos --register-unsafely-without-email \
            || { echo "✗ 申请失败"; exit 1; }
        ;;

    3)
        echo "⏳ 使用 Manual DNS 方式申请 $domain ..."
        echo "   请按下方提示，在域名 DNS 管理面板添加对应的 TXT 记录"
        echo ""
        certbot certonly --manual --preferred-challenges dns $cert_domains \
            --agree-tos --register-unsafely-without-email \
            || { echo "✗ 申请失败"; exit 1; }
        ;;

    4)
        echo "⏳ 安装 Cloudflare 插件..."
        apt-get install -y -qq python3-certbot-dns-cloudflare 2>/dev/null || {
            echo "✗ 安装 Cloudflare 插件失败"
            exit 1
        }
        cf_config=$(setup_cloudflare_creds)
        echo "⏳ 使用 Cloudflare DNS 方式申请 $domain ..."
        certbot certonly --dns-cloudflare \
            --dns-cloudflare-credentials "$cf_config" \
            $cert_domains --non-interactive --agree-tos --register-unsafely-without-email \
            || { echo "✗ 申请失败"; exit 1; }
        ;;
esac

echo "✔ 证书申请成功！"

# 申请成功后立即同步一次
sync_certificates

# 设置 crontab（续签 + 同步）
setup_crontab

# 询问是否继续添加其他域名
echo ""
read -p "是否继续添加其他域名? (yes/no): " answer
if [[ "$answer" == "yes" || "$answer" == "y" ]]; then
    exec "$0" 2
fi
