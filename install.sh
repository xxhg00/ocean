#!/usr/bin/env bash
# ocean 节点安装脚本（通用：不含面板地址和密钥，全部用参数传入）
#
# 用法：
#   bash install.sh -p 面板地址 -k 对接密钥 [-n 节点名] [-m "镜像地址1 镜像地址2"] [--force]
#
# 一台服务器可以对接多个设备组：用另一个组的对接命令再运行一次，会自动新增一个实例（oceand-g组号），
# 和原来的互不影响。同一个组重复运行会跳过；--force = 这个组里重新注册一遍。
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
FORCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--panel) PANEL="${2:-}"; shift 2 ;;
    -k|--key) KEY="${2:-}"; shift 2 ;;
    -n|--name) NAME="${2:-}"; NAME_SET=1; shift 2 ;;
    -m|--mirrors) MIRRORS="${2:-}"; shift 2 ;;
    -f|--force) FORCE="--force"; shift ;;
    *) echo "未知参数: $1（可用: -p 面板地址  -k 对接密钥  -n 节点名  -m 镜像地址  --force 重新注册）"; exit 1 ;;
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
# 支持 systemd（绝大多数 Linux）和 OpenRC（Alpine）
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then INIT=systemd
elif command -v rc-service >/dev/null 2>&1 && [ -x /sbin/openrc-run ]; then INIT=openrc
elif command -v systemctl >/dev/null 2>&1; then INIT=systemd
else echo "需要 systemd 或 OpenRC（Alpine）"; exit 1; fi

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
  sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-oceand.conf >/dev/null 2>&1 || true
  [ "$CC" = "bbr" ] || echo "  提示：这台机器的内核没有 BBR（需要 4.9 以上内核），已保持 $CC。"
fi
if [ "${INSTALL_TOOLS:-0}" = "1" ]; then
  echo "正在安装常用工具 ..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    # 新开的机器软件源列表常常是空的/过期的，先更新；再逐个安装，一个失败不影响其他
    apt-get update -qq >/dev/null 2>&1 || apt-get update -qq >/dev/null 2>&1 || true
    FAILED=""
    for p in curl wget vim htop iperf3 mtr-tiny dnsutils net-tools unzip tcpdump; do
      apt-get install -y -qq "$p" >/dev/null 2>&1 || apt-get install -y -qq "$p" >/dev/null 2>&1 || FAILED="$FAILED $p"
    done
    [ -n "$FAILED" ] && echo "  这些工具没装上：$FAILED （可以稍后手动 apt-get install）"
  elif command -v apk >/dev/null 2>&1; then
    apk update -q >/dev/null 2>&1 || true
    FAILED=""
    for p in curl wget vim htop iperf3 mtr bind-tools net-tools unzip tcpdump; do
      apk add -q --no-cache "$p" >/dev/null 2>&1 || apk add -q --no-cache "$p" >/dev/null 2>&1 || FAILED="$FAILED $p"
    done
    [ -n "$FAILED" ] && echo "  这些工具没装上：$FAILED （可以稍后手动 apk add）"
  else
    echo "  不是 Debian / Ubuntu / Alpine，跳过。"
  fi
fi

SRCBIN="$TMP"
# ---- 装程序（先写临时文件再改名：别的实例正在运行也不受影响）
CHANGED=1
if [ -f /usr/local/bin/oceand ] && cmp -s "$SRCBIN" /usr/local/bin/oceand 2>/dev/null; then CHANGED=0; fi
cp "$SRCBIN" /usr/local/bin/oceand.new && chmod 755 /usr/local/bin/oceand.new && mv -f /usr/local/bin/oceand.new /usr/local/bin/oceand || { echo "写入 /usr/local/bin/oceand 失败"; exit 1; }

# ---- 注册。一台服务器可以对接多个设备组：密钥属于别的组时自动新增一个实例（oceand-g组号）
INSTF="$(mktemp /tmp/oceand.inst.XXXXXX)"
SUF=""
/usr/local/bin/oceand register --panel "$PANEL" --key "$KEY" --name "$NAME" --multi --inst-out "$INSTF" $FORCE
RC=$?
if [ "$RC" = 2 ]; then # 很老的节点程序不认识 --multi：按老办法注册
  /usr/local/bin/oceand register --panel "$PANEL" --key "$KEY" --name "$NAME" $FORCE; RC=$?
else
  SUF="$(cat "$INSTF" 2>/dev/null)"
fi
rm -f "$INSTF"
if [ "$RC" != 0 ]; then
  echo "注册失败，请检查对接密钥是否正确（面板上重置过密钥的话要用新的）。"
  exit 1
fi
case "$SUF" in ""|-[A-Za-z0-9-]*) ;; *) SUF="" ;; esac
SVC="oceand$SUF"
DIR="/etc/oceand$SUF"
mkdir -p "$DIR"; chmod 700 "$DIR"

if [ "$INIT" = openrc ]; then
cat > "/etc/init.d/$SVC" <<RC
#!/sbin/openrc-run
name="$SVC"
description="ocean node service"
command="/usr/local/bin/oceand"
command_args="run"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
output_log="/var/log/$SVC.log"
error_log="/var/log/$SVC.log"
export OCEAN_DIR=$DIR

depend() {
	want net
	after firewall
}

start_pre() {
	# 日志超过 5MB 就清空，免得一直变大
	if [ -f /var/log/$SVC.log ] && [ "\$(wc -c < /var/log/$SVC.log)" -gt 5242880 ]; then : > /var/log/$SVC.log; fi
}
RC
chmod 755 "/etc/init.d/$SVC"
rc-update add "$SVC" default >/dev/null 2>&1
rc-service "$SVC" restart >/dev/null 2>&1 || rc-service "$SVC" start
else
cat > "/etc/systemd/system/$SVC.service" <<UNIT
[Unit]
Description=ocean node service ($SVC)
After=network-online.target
Wants=network-online.target

[Service]
Environment=OCEAN_DIR=$DIR
ExecStart=/usr/local/bin/oceand run
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "$SVC" >/dev/null 2>&1
systemctl restart "$SVC"
fi
# 程序换了新版本：本机其他实例也重启一下，用上新程序
if [ "$CHANGED" = 1 ]; then
  for d in /etc/oceand /etc/oceand-*; do
    [ -f "$d/state.json" ] || continue
    o="$(basename "$d")"; [ "$o" = "$SVC" ] && continue
    if [ "$INIT" = openrc ]; then rc-service "$o" restart >/dev/null 2>&1 || true; else systemctl restart "$o" 2>/dev/null || true; fi
  done
fi
cat > /opt/oceand.uninstall.sh <<'UNI'
#!/usr/bin/env bash
# 卸载本机全部 ocean 节点实例。只卸载其中一个：bash /opt/oceand.uninstall.sh oceand-g15
ONLY="${1:-}"
for d in /etc/oceand /etc/oceand-*; do
  [ -d "$d" ] || continue
  s="$(basename "$d")"
  [ -n "$ONLY" ] && [ "$s" != "$ONLY" ] && continue
  if [ -f "/etc/init.d/$s" ] && command -v rc-service >/dev/null 2>&1; then
    rc-service "$s" stop 2>/dev/null || true
    rc-update del "$s" default 2>/dev/null || true
    rm -f "/etc/init.d/$s" "/var/log/$s.log"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$s" 2>/dev/null || true
    rm -f "/etc/systemd/system/$s.service"
  fi
  rm -rf "$d"
  echo "已卸载 $s"
done
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null || true
LEFT=0
for f in /etc/oceand/state.json /etc/oceand-*/state.json; do [ -f "$f" ] && LEFT=1; done
if [ "$LEFT" = 0 ]; then
  rm -f /usr/local/bin/oceand /usr/local/bin/oceand.new*
  rm -f /opt/oceand.uninstall.sh
  echo "ocean 已卸载"
fi
UNI
chmod 755 /opt/oceand.uninstall.sh
if [ "$INIT" = openrc ]; then echo "安装成功（$SVC）。查看日志: tail -f /var/log/$SVC.log"; else echo "安装成功（$SVC）。查看日志: journalctl -fu $SVC"; fi
N_INST=0
for f in /etc/oceand/state.json /etc/oceand-*/state.json; do [ -f "$f" ] && N_INST=$((N_INST+1)); done
if [ "$N_INST" -gt 1 ]; then
  echo "本机现在对接了 $N_INST 个设备组。只卸载这一个: bash /opt/oceand.uninstall.sh $SVC"
  echo "全部卸载: bash /opt/oceand.uninstall.sh"
else
  echo "如需卸载，请运行以下命令："
  echo "bash /opt/oceand.uninstall.sh"
fi
echo
echo "tcp_congestion_control:  $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)   default_qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
BBRV="$(modinfo tcp_bbr 2>/dev/null | awk -F': *' '/^version/{print $2}')"
if [ -n "$BBRV" ]; then echo "tcp_bbr 模块版本: $BBRV（1 = BBRv1；BBRv3 需要 XanMod 等带 BBRv3 的内核）"; fi
exit 0
