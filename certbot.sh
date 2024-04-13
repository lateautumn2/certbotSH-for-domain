#!/bin/bash

# 安装 Certbot
apt-get update
apt-get install certbot

# 询问用户是申请二级域名证书还是泛域名证书
echo "你想申请? (1) 二级域名证书 (2) 泛域名证书"
read -p "请输入1或者2: " cert_choice

while true; do
    # 输入域名
    read -p "输入你要申请的域名 (e.g., example.com): " domain

    if [[ $cert_choice == "2" ]]; then
        # 安装 Cloudflare 插件
        apt-get install python3-certbot-dns-cloudflare

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
    elif [[ $cert_choice == "1" ]]; then
        # 使用 Certbot 的 Standalone 插件申请二级域名证书
        if certbot certonly --standalone -d "$domain"; then
            echo "成功! 已经获取到 $domain 的证书."
        else
            echo "无法获取 $domain 的二级域名证书。请检查您的域名设置并重试."
            exit 1
        fi
    else
        echo "无效选择。请再次运行该脚本并选择 1 或 2."
        exit 1
    fi

    # 定义证书的存储目录和目标目录
    certbot_cert_path="/etc/letsencrypt/live/$domain"
    target_cert_path="/root/cert/$domain/"

    # 确保目标目录存在
    mkdir -p "$target_cert_path"

    # 复制证书和密钥到目标目录
    if [[ -d "$certbot_cert_path" ]]; then
        cp "$certbot_cert_path/fullchain.pem" "$target_cert_path${domain}_fullchain.pem"
        cp "$certbot_cert_path/privkey.pem" "$target_cert_path${domain}_privkey.pem"
        echo "成功! 关于 $domain 的证书及密钥已经存放至 $target_cert_path."
    else
        echo "注意：无法将证书和密钥复制到目标目录。这可能是由于未颁发证书造成的."
    fi

    # 询问是否继续
    read -p "是否继续添加其他域名? (yes/no): " answer
    if [[ "$answer" != "yes" ]]; then
        break
    fi
done
