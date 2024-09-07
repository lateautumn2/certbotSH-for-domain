#!/bin/bash

# 函数：同步所有证书
sync_certificates() {
    # 遍历 /etc/letsencrypt/live/ 下的所有目录（每个域名）
    for domain_dir in /etc/letsencrypt/live/*/; do
        domain=$(basename "$domain_dir")

        # 定义证书存储目录和目标目录
        certbot_cert_path="/etc/letsencrypt/live/$domain"
        target_cert_path="/root/cert/$domain/"

        # 确保目标目录存在
        mkdir -p "$target_cert_path"

        # 复制证书和密钥到目标目录
        if [[ -d "$certbot_cert_path" ]]; then
            cp "$certbot_cert_path/fullchain.pem" "$target_cert_path${domain}_fullchain.pem"
            cp "$certbot_cert_path/privkey.pem" "$target_cert_path${domain}_privkey.pem"
            echo "成功! 已将关于 $domain 的证书及密钥复制到 $target_cert_path."
        else
            echo "注意：无法将 $domain 的证书和密钥复制到目标目录。这可能是由于未颁发证书造成的."
        fi
    done
}

# 如果没有提供参数，则使用默认值 1
sh_type=${1:-2}

if [[ $sh_type == "1" ]]; then
    # 如果选择了同步证书，直接执行同步
    sync_certificates
else
    # 安装 Certbot
    apt-get install -y certbot

    # 询问用户是申请二级域名证书还是泛域名证书
    echo "你想申请? (1) 二级域名证书 (2) 泛域名证书"
    read -p "请输入1或者2: " cert_choice

    # 输入域名
    read -p "输入你要申请的域名 (e.g., example.com): " domain

    case $cert_choice in
        1)
            # 使用 Certbot 的 Standalone 插件申请二级域名证书
            if certbot certonly --standalone -d "$domain"; then
                echo "成功! 已经获取到 $domain 的证书."
            else
                echo "无法获取 $domain 的二级域名证书。请检查您的域名设置并重试."
                exit 1
            fi
            ;;
        2)
            # 安装 Cloudflare 插件
            apt-get install -y python3-certbot-dns-cloudflare

            # 输入 Cloudflare API Key 和 Email
            read -p "输入你的 Cloudflare API Key: " cloudflare_api_key
            read -p "输入你的 Cloudflare Email: " cloudflare_email

            # 创建 Cloudflare 配置文件
            cloudflare_config_path="/etc/letsencrypt/cloudflare.ini"
            echo "dns_cloudflare_email = $cloudflare_email" > "$cloudflare_config_path"
            echo "dns_cloudflare_api_key = $cloudflare_api_key" >> "$cloudflare_config_path"
            chmod 600 "$cloudflare_config_path"

            # 使用 Cloudflare DNS 插件申请泛域名证书
            if certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$cloudflare_config_path" -d "$domain" -d "*.$domain"; then
                echo "成功! 已经获取到 $domain 和 *.$domain 的证书."
            else
                echo "无法获取 $domain 的通配符证书。请检查您的域名设置并重试."
                exit 1
            fi
            ;;
        *)
            echo "无效选择。请再次运行该脚本并选择 1 或 2."
            exit 1
            ;;
    esac

    # 添加自动续签任务到 crontab
    # 获取当前脚本的绝对路径
    current_script_path=$(realpath "$0")
    (crontab -l; echo "0 3 * * * /usr/bin/certbot renew --quiet --deploy-hook '$current_script_path 1'") | crontab -

    sync_certificates

    # 询问是否继续
    read -p "是否继续添加其他域名? (yes/no): " answer
    if [[ "$answer" != "yes" ]]; then
        exit 0
    fi
fi
