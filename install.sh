#!/usr/bin/env bash
# ocean 节点安装脚本（通用：不含面板地址和密钥，全部用参数传入）
#
# 用法：
#   bash install.sh -p 面板地址 -k 对接密钥 [-n 节点名] [-m "镜像地址1 镜像地址2"]
#
# 程序来源按顺序尝试，哪个成功用哪个：
#   1. 当前目录 / 脚本所在目录里的 oceand-linux-<架构>（离线包就是这种情况）
#   2. -m 里的镜像地址，一个失败自动换下一个（镜像目录里要有 oceand-linux-amd64 / oceand-linux-arm64 / SHA256SUMS）
#   3. 面板自己的下载地址
# 前两种来源会用 SHA256SUMS 校验。
set -uo pipefail

PANEL=""
KEY="${OCEAN_KEY:-}"
NAME="${OCEAN_NAME:-$(hostname)}"
NAME_SET="${OCEAN_NAME:+1}"
MIRRORS="${OCEAN_MIRRORS:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--panel) PANEL="${2:-}"; shift 2 ;;
    -k|--key) KEY="${2:-}"; shift 2 ;;
    -n|--name) NAME="${2:-}"; NAME_SET=1; shift 2 ;;
    -m|--mirrors) MIRRORS="${2:-}"; shift 2 ;;
    *) echo "未知参数: $1（可用: -p 面板地址  -k 对接密钥  -n 节点名  -m 镜像地址）"; exit 1 ;;
  esac
done
PANEL="${PANEL%/}"

if [ "$(id -u)" != "0" ]; then echo "请用 root 运行"; exit 1; fi
# 没用 -n 指定节点名、又是在终端里手动运行时：问一下节点名（直接回车 = 用主机名；60 秒没输入也用主机名）
if [ -z "$NAME_SET" ] && { true </dev/tty; } 2>/dev/null; then
  printf '节点名称（直接回车使用 "%s"）: ' "$NAME" >/dev/tty
  _IN=""
  read -r -t 60 _IN </dev/tty || true
  _IN="$(printf '%s' "$_IN" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$_IN" ] && NAME="$_IN"
  echo "节点名称: $NAME" >/dev/tty
fi
if [ -z "$PANEL" ]; then echo "缺少面板地址：请加上 -p http://面板地址:端口"; exit 1; fi
_H="${PANEL#*://}"; _H="${_H%%[/:]*}"
if echo "$_H" | grep -Eq '^[0-9.]+$|^\[?[0-9a-fA-F:]+\]?$' && echo "$_H" | grep -q '[.:]' && ! echo "$_H" | grep -q '[g-zG-Z]'; then echo "面板地址不能是纯 IP，请改用域名（如 https://panel.example.com）"; exit 1; fi
if [ -z "$KEY" ]; then echo "缺少对接密钥：请加上 -k 你的对接密钥"; exit 1; fi
if ! command -v systemctl >/dev/null 2>&1; then echo "需要 systemd"; exit 1; fi

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "不支持的 CPU 架构: $(uname -m)"; exit 1 ;;
esac
BIN="oceand-linux-$ARCH"
TMP="$(mktemp /tmp/oceand.XXXXXX)"
trap 'rm -f "$TMP" "$TMP.sums"' EXIT

sha_ok() { # $1 文件  $2 SHA256SUMS 文件
  command -v sha256sum >/dev/null 2>&1 || return 0
  local want got
  want="$(grep " $BIN\$" "$2" | awk '{print $1}' | head -n1)"
  [ -n "$want" ] || return 1
  got="$(sha256sum "$1" | awk '{print $1}')"
  [ "$want" = "$got" ]
}

GOT=""
# 1. 本地文件（离线包）
for d in "$PWD" "$(cd "$(dirname "$0")" 2>/dev/null && pwd)"; do
  if [ -n "$d" ] && [ -f "$d/$BIN" ]; then
    if [ -f "$d/SHA256SUMS" ] && ! sha_ok "$d/$BIN" "$d/SHA256SUMS"; then echo "本地文件 $d/$BIN 校验失败，跳过"; continue; fi
    cp "$d/$BIN" "$TMP" && GOT="本地文件 $d/$BIN" && break
  fi
done
# 2. 镜像
if [ -z "$GOT" ]; then
  for m in $MIRRORS; do
    m="${m%/}"
    echo "尝试镜像 $m ..."
    if curl -fsSL --connect-timeout 8 --max-time 300 --speed-time 15 --speed-limit 20000 "$m/$BIN" -o "$TMP" 2>/dev/null \
       && curl -fsSL --connect-timeout 8 --max-time 30 "$m/SHA256SUMS" -o "$TMP.sums" 2>/dev/null \
       && sha_ok "$TMP" "$TMP.sums"; then
      GOT="镜像 $m"; break
    fi
    echo "  这个镜像不可用，换下一个"
  done
fi
# 3. 面板
if [ -z "$GOT" ]; then
  echo "尝试从面板下载 ..."
  if curl -fsSL --connect-timeout 10 --max-time 600 --speed-time 20 --speed-limit 10000 "$PANEL/agent/bin/linux-$ARCH" -o "$TMP"; then GOT="面板 $PANEL"; fi
fi
if [ -z "$GOT" ]; then
  echo "没能拿到节点程序：本地没有离线文件，镜像和面板都下载失败。"
  echo "可以：换一台能访问的机器下载离线包，上传到本机当前目录后再运行本脚本；或检查面板 $PANEL 的防火墙 / 安全组是否放行。"
  exit 1
fi
echo "节点程序来源：$GOT"

# 面板要能连上，节点才能注册
if ! curl -sS -m 10 -o /dev/null "$PANEL" 2>/dev/null; then
  echo "连不上面板 $PANEL（10 秒无响应）。请检查：面板服务器的防火墙 / 云厂商安全组是否放行了面板端口，以及本机能否访问它。"
  exit 1
fi

# ---- 可选：优化系统参数 / 安装常用工具（环境变量 OPTIMIZE=1 INSTALL_TOOLS=1 可免交互；设成 0 表示不做）
can_ask() { { : </dev/tty; } 2>/dev/null; }
ask_yn() { # $1 提示  → 输入 y 返回 0
  can_ask || return 1
  local a=""; read -r -p "$1" a </dev/tty || return 1
  [ "$a" = "y" ] || [ "$a" = "Y" ]
}
if [ -z "${OPTIMIZE:-}" ]; then ask_yn "是否优化系统参数（开启 BBR / 调大缓冲区，输入 y 优化）: " && OPTIMIZE=1; fi
if [ -z "${INSTALL_TOOLS:-}" ]; then ask_yn "是否安装常用工具（curl wget htop mtr iperf3 等，输入 y 安装）: " && INSTALL_TOOLS=1; fi

if [ "${OPTIMIZE:-0}" = "1" ]; then
  echo "正在优化系统参数 ..."
  modprobe tcp_bbr 2>/dev/null || true
  CC=cubic
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then CC=bbr; fi
  cat > /etc/sysctl.d/99-oceand.conf <<SYS
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $CC
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 131072
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
SYS
  sysctl --system >/dev/null 2>&1 || true
  [ "$CC" = "bbr" ] || echo "  提示：这台机器的内核没有 BBR（需要 4.9 以上内核），已保持 $CC。"
fi
if [ "${INSTALL_TOOLS:-0}" = "1" ]; then
  echo "正在安装常用工具 ..."
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl wget vim htop iperf3 mtr-tiny dnsutils net-tools unzip tcpdump >/dev/null 2>&1 || echo "  部分工具安装失败，可以稍后手动安装。"
  else
    echo "  不是 Debian / Ubuntu，跳过。"
  fi
fi

systemctl stop oceand 2>/dev/null || true
install -m 755 "$TMP" /usr/local/bin/oceand
mkdir -p /etc/oceand
chmod 700 /etc/oceand
if ! /usr/local/bin/oceand register --panel "$PANEL" --key "$KEY" --name "$NAME"; then
  echo "注册失败，请检查对接密钥是否正确（面板上重置过密钥的话要用新的）。"
  exit 1
fi

cat > /etc/systemd/system/oceand.service <<'UNIT'
[Unit]
Description=ocean node service
After=network-online.target
Wants=network-online.target

[Service]
Environment=OCEAN_DIR=/etc/oceand
ExecStart=/usr/local/bin/oceand run
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable oceand >/dev/null 2>&1
systemctl restart oceand
cat > /opt/oceand.uninstall.sh <<'UNI'
#!/usr/bin/env bash
systemctl disable --now oceand 2>/dev/null || true
rm -f /etc/systemd/system/oceand.service /usr/local/bin/oceand /usr/local/bin/oceand.new
rm -rf /etc/oceand
systemctl daemon-reload
rm -f /opt/oceand.uninstall.sh
echo "ocean 已卸载"
UNI
chmod 755 /opt/oceand.uninstall.sh
echo "安装成功。查看日志: journalctl -fu oceand"
echo "如需卸载，请运行以下命令："
echo "bash /opt/oceand.uninstall.sh"
echo
echo "tcp_congestion_control:  $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)   default_qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
BBRV="$(modinfo tcp_bbr 2>/dev/null | awk -F': *' '/^version/{print $2}')"
[ -n "$BBRV" ] && echo "tcp_bbr 模块版本: $BBRV（1 = BBRv1；BBRv3 需要 XanMod 等带 BBRv3 的内核）"
