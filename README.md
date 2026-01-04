
安装
```
curl -Ls https://raw.githubusercontent.com/eishare/test/main/test.sh | bash -s tuic="" argo="0"
```


卸载
```
curl -Ls https://raw.githubusercontent.com/eishare/test/main/test.sh | bash -s uninstall
```

卸载内容
```
pkill sing-box
pkill cloudflared
pkill httpd
rm -rf /etc/sing-box /usr/bin/sing-box /usr/bin/cloudflared /var/www/html/*
```
