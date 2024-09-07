# certbotSH-for-domain
通过certbot申请域名证书
``` bash
wget https://raw.githubusercontent.com/lateautumn2/certbotSH-for-domain/main/certbot.sh
chmod +x certbot.sh

#签发证书
./certbot.sh

#同步证书文件
./certbot.sh 1
```

默认会添加crontab自动renew并同步证书文件
如果您认为此脚本有不足或者BUG，欢迎提交PR，thanks
