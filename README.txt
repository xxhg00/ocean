ocean 节点安装包 v0.6.10（通用，不含面板地址和密钥）

一、当镜像用（推荐）
1. 新建一个公开仓库，把本目录里的 4 个文件原样放到仓库根目录：install.sh、oceand-linux-amd64、oceand-linux-arm64、SHA256SUMS（VERSION 可选）。
2. 镜像地址就是“文件所在目录”，例如：
   境外：https://raw.githubusercontent.com/你的用户名/仓库名/main
   境内：https://cdn.jsdelivr.net/gh/你的用户名/仓库名@main   （jsDelivr 对分支有缓存，更新程序后建议打 tag，用 @标签名）
   也可以放到别的静态空间 / 对象存储，只要能直接下载这几个文件。
3. 面板“站点设置 → 节点安装镜像”里境外、境内各填一个或多个地址（每行一个），对接弹窗就会生成带自动换源的命令。
4. 升级节点程序后，把新的 oceand-linux-* 和 SHA256SUMS 一起覆盖上传。

二、当离线包用
把整个目录传到节点服务器，在目录里运行：
  bash install.sh -p http://面板地址:端口 -k 对接密钥 [-n 节点名]
脚本会优先使用同目录的程序文件，不需要联网下载。节点仍需要能访问面板地址。
