# NNU RustDesk 容器更新服务

服务地址：`https://rd.nnu.cn/client-updates/stable.json`。
容器仅提供只读文件服务，绑定服务器 `127.0.0.1:32170`，由现有 OpenResty 代理 HTTPS。
不提供公开上传或管理接口。更新不涉及现有 hbbs、hbbr、API 容器。

## 部署

部署目录 `/opt/nnu-rustdesk-updates`，包含 compose.yaml、nginx.conf 和 public/。
执行 `docker compose up -d`，检查容器健康和 `curl http://127.0.0.1:32170/healthz`。
在现有 rd.nnu.cn 的 HTTPS server 内添加：

```nginx
location ^~ /client-updates/ {
    proxy_pass http://127.0.0.1:32170/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_buffering off;
}
```

修改前备份原配置；`nginx -t` 通过后 reload。回退时删除该 location 并 reload，停止更新容器即可。

## 发布新版

1. 在本机编译新版，并将 `nnu_update_service.dart` 的 `nnuClientBuild` 增大；同时更新 `nnuClientVersion`。
2. 本机 Python 需要 `cryptography`。签名私钥在 `%USERPROFILE%\.codex\tools\nnu-build\private\nnu-update-ed25519.pem`，应私下备份，勿放入仓库、下载目录或服务器。
3. 更新说明保存为 UTF-8 文本。运行：

```powershell
py res/nnu/update-server/publish.py --source <构建产物目录> --output <发布目录> --key <私钥路径> --build 2026103105 --version "1.5.0 NNU UI5" --notes <更新说明.txt>
```

4. 通过 SSH/SFTP 上传发布目录的 releases/ 到服务器 public/releases/。每个 build 不可覆盖；先核对文件哈希。
5. 最后上传 stable.json.tmp，再在同一目录原子重命名为 stable.json。不要先发布清单后传安装包。

可用配套脚本自动完成第 4–5 步（需要 Python paramiko），密码交互输入，也支持 `--identity <SSH私钥>`：

```powershell
py res/nnu/update-server/upload.py --source <发布目录> --host <服务器IP> --user ubuntu
```

客户端启动后检查一次，也可点底部“检查更新”。只接受内置公钥验证通过的 Ed25519 清单和同一 HTTPS 路径内的安装包。下载后验证大小及 SHA-256，再提供打开安装包/文件位置按钮。不会自动重启客户端或静默安装。安装操作会提醒中断远程会话，已检测到被控会话时阻止启动安装。

UI2/UI3 等旧版尚无更新入口，需要手动安装一次带更新功能的 UI4；此后可通过自建服务持续分发。
“已就绪”指 ID 服务连接，与更新服务是否在线独立；更新服务失败不应改变远控状态。
