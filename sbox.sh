#!/bin/bash
# =====================================================================
#  sbox 一键安装脚本 —— sing-box 1.14.0 精简定制版 (cloudflared 版)
#  支持: Debian/Ubuntu (systemd) / Alpine (OpenRC 或 systemd)
#  功能: 装依赖 → 下二进制(/opt/sbox/sbox) → 装菜单(/usr/local/bin/sbox)
#        → 注册开机自启服务(sbox) → 初始化配置
#
#  下载地址已填: https://sb.vir.kdns.fr/sbox
#    多架构: 优先尝试 ${DOWNLOAD_BASE}-amd64 / -arm64 / -armv7 / -386，不存在则回退 ${DOWNLOAD_BASE}
#    临时换源: SBOX_DOWNLOAD_BASE=https://x.com/sbox bash sbox-install.sh
#    离线安装: SBOX_LOCAL_BIN=/path/to/sbox bash sbox-install.sh
#
#  本版本仅支持: vless/vmess (ws/http/httpupgrade/tcp + TLS + REALITY)、
#              Cloudflare Tunnel 入口、Socks/HTTP 入口、direct/block/分组出口
# =====================================================================
set -e

DOWNLOAD_BASE="${SBOX_DOWNLOAD_BASE:-https://sb.vir.kdns.fr/sbox}"
LIB_DIR=/opt/sbox
ETC_DIR=/etc/sbox
LOGF=/var/log/sbox.log

[ "$(id -u)" = 0 ] || { echo "✘ 请用 root 运行: sudo bash $0"; exit 1; }

# ---------- 发行版检测 & 依赖 ----------
. /etc/os-release 2>/dev/null || true
PKG=""
case "${ID:-}" in
  debian|ubuntu|raspbian) PKG=apt;;
  alpine) PKG=apk;;
esac
echo ">> 系统: ${PRETTY_NAME:-unknown}  包管理器: ${PKG:-none}"
if [ "$PKG" = apt ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl jq ca-certificates bash openssl >/dev/null
elif [ "$PKG" = apk ]; then
  apk add --no-cache curl jq bash ca-certificates openssl >/dev/null
fi
command -v curl >/dev/null || { echo "✘ 缺 curl，请先手动安装"; exit 1; }
command -v jq   >/dev/null || { echo "✘ 缺 jq，请先手动安装"; exit 1; }

# ---------- 架构映射 ----------
M=$(uname -m); case $M in
  x86_64) A=amd64;; aarch64|arm64) A=arm64;; armv7l|armv7) A=armv7;;
  i386|i686) A=386;; *) A=$M;; esac

# ---------- 下载/安装二进制 ----------
mkdir -p "$LIB_DIR" "$ETC_DIR"
if [ -n "${SBOX_LOCAL_BIN:-}" ] && [ -f "$SBOX_LOCAL_BIN" ]; then
  cp -f "$SBOX_LOCAL_BIN" "$LIB_DIR/sbox.tmp" && mv -f "$LIB_DIR/sbox.tmp" "$LIB_DIR/sbox"
  echo ">> 使用本地二进制: $SBOX_LOCAL_BIN"
else
  URL="${DOWNLOAD_BASE}-${A}"
  curl -fsIL --retry 2 --max-time 15 "$URL" >/dev/null 2>&1 || URL="$DOWNLOAD_BASE"   # 无架构版则回退单文件
  echo ">> 下载 $URL ..."
  curl -fL --retry 3 -o "$LIB_DIR/sbox.tmp" "$URL"
  mv -f "$LIB_DIR/sbox.tmp" "$LIB_DIR/sbox"   # 原子替换，避开运行中二进制的 ETXTBSY
fi
chmod 755 "$LIB_DIR/sbox"
"$LIB_DIR/sbox" version | head -1

# ---------- 初始配置 ----------
if [ ! -f "$ETC_DIR/config.json" ]; then
  jq -n --arg l "$LOGF" '{log:{level:"info",output:$l},inbounds:[],outbounds:[{type:"direct",tag:"direct"}]}' > "$ETC_DIR/config.json"
  echo ">> 已生成初始配置 $ETC_DIR/config.json"
fi

# ---------- 管理菜单 ----------
echo ">> 安装管理菜单 /usr/local/bin/sbox"
cat > /usr/local/bin/sbox <<'SBOXMENU_EOF'
#!/bin/bash
# sbox 管理菜单 —— sing-box 1.14.0 精简版 (vless/vmess + ws/http/h2/httpupgrade/reality + cloudflared + socks/http)
# 由 sbox-install.sh 自动安装到 /usr/local/bin/sbox

BIN=${SBOX_BIN:-/opt/sbox/sbox}
ETC=${SBOX_ETC:-/etc/sbox}
CFG=$ETC/config.json
LOGF=${SBOX_LOG:-/var/log/sbox.log}
PIDF=/run/sbox-manual.pid
DLBASE=${SBOX_DOWNLOAD_BASE:-https://sb.vir.kdns.fr/sbox}
G=$'\e[1;32m'; Y=$'\e[1;33m'; R=$'\e[1;31m'; C=$'\e[1;36m'; N=$'\e[0m'

ok()   { printf "%s✔ %s%s\n" "$G" "$1" "$N"; }
warn() { printf "%s⚠ %s%s\n" "$Y" "$1" "$N"; }
err()  { printf "%s✘ %s%s\n" "$R" "$1" "$N"; }
pause(){ printf "\n按回车继续..."; read -r _ ; }

ARCH=$(uname -m); case $ARCH in
  x86_64) A=amd64;; aarch64|arm64) A=arm64;; armv7l|armv7) A=armv7;;
  i386|i686) A=386;; *) A=$ARCH;; esac

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'
  else printf '%04x%04x-%04x-4%03x-%04x-%04x%04x%04x\n' $((RANDOM)) $((RANDOM)) $((RANDOM)) $((RANDOM%4096)) $((RANDOM)) $((RANDOM)) $((RANDOM)) $((RANDOM)); fi
}

server_ip() {
  local ip="" age now
  now=$(date +%s)
  if [ -f "$ETC/.pubip" ]; then
    age=$(( now - $(stat -c %Y "$ETC/.pubip" 2>/dev/null || stat -r %m "$ETC/.pubip" 2>/dev/null || echo 0) ))
    [ "$age" -lt 86400 ] && ip=$(cat "$ETC/.pubip" 2>/dev/null)
  fi
  [ -z "$ip" ] && ip=$(curl -s -m 5 https://api.ipify.org 2>/dev/null)
  [ -z "$ip" ] && ip=$(curl -s -m 5 http://ip.sb 2>/dev/null)
  if [ -n "$ip" ]; then printf '%s' "$ip" > "$ETC/.pubip" 2>/dev/null
  else
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  fi
  echo "$ip"
}

# ---------- 服务控制 ----------
manual_svc() {
  case "$1" in
    start)   nohup "$BIN" run -D "$ETC" -c "$CFG" >>"$LOGF" 2>&1 & echo $! >"$PIDF"; ok "已后台启动 (pid $(cat $PIDF))";;
    stop)    if [ -f "$PIDF" ]; then local p=$(cat "$PIDF"); kill "$p" 2>/dev/null
               for _i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$p" 2>/dev/null || break; sleep 0.3; done
               kill -9 "$p" 2>/dev/null; rm -f "$PIDF"; fi; ok "已停止";;
    restart) manual_svc stop; sleep 1; manual_svc start;;
    status)  if [ -f "$PIDF" ] && kill -0 "$(cat $PIDF)" 2>/dev/null; then echo "running (pid $(cat $PIDF))"; else echo "stopped"; fi;;
    enable|disable) warn "无服务管理器，无法设置自启；开机请自行加入 rc.local/crontab @reboot";;
  esac
}
svc() {
  if [ -n "$SBOX_FORCE_MANUAL" ]; then manual_svc "$@"; return; fi
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then systemctl "$@" sbox
  elif command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/sbox ]; then
    case "$1" in
      enable) rc-update add sbox default;; disable) rc-update del sbox default;;
      status) rc-service sbox status;; *) rc-service sbox "$1";; esac
  elif [ -f /etc/init.d/sbox ]; then /etc/init.d/sbox "$@"
  else manual_svc "$@"; fi
}

# ---------- 配置读写 ----------
load_cfg() { [ -f "$CFG" ] || { err "$CFG 不存在，请先运行安装脚本"; exit 1; }; }

apply_cfg() { # $CFG 已由子流程改到 $TMPNEW
  local tmp; tmp=$(mktemp)
  if ! jq . "$TMPNEW" >"$tmp" 2>/dev/null; then err "JSON 语法错误，已放弃"; rm -f "$tmp"; return 1; fi
  if ! "$BIN" check -c "$tmp" 2>/tmp/sbox-check.err; then err "配置校验失败：$(tail -2 /tmp/sbox-check.err | tr '\n' ' ')"; rm -f "$tmp"; return 1; fi
  mkdir -p "$ETC/backup"
  cp "$CFG" "$ETC/backup/config.$(date +%Y%m%d-%H%M%S).json" 2>/dev/null
  ls -t "$ETC/backup"/config.*.json 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null
  mv "$tmp" "$CFG"; ok "已写入 $CFG (旧版已备份)"
  printf "立即重启服务生效? [Y/n]: "; read -r r; case "$r" in [nN]*) warn "稍后到[5]运行管理里重启";; *) svc restart && ok "服务已重启";; esac
}

list_inbounds() {
  jq -r '.inbounds // [] | to_entries[] | "  \(.key+1)) \(.value.type)  tag=\(.value.tag // "-")  port=\(.value.listen_port // "-")"' "$CFG"
}
ask_idx() { # 输入序号 -> 全局变量 IDX (0基)
  local n cnt; cnt=$(jq '(.inbounds // []) | length' "$CFG")
  [ "$cnt" = 0 ] && { warn "当前没有配置，先去[1]添加"; return 1; }
  list_inbounds; printf "序号 [1-$cnt]: "; read -r n
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$cnt" ] || { err "无效序号"; return 1; }
  IDX=$((n-1)); }

# ---------- 添加各类入口 ----------
ask_tls() { # 全局 CERT KEY；回车跳过=不启用
  printf "证书路径 (回车跳过TLS，明文适合套CDN/隧道): "; read -r CERT
  [ -z "$CERT" ] && { KEY=""; return; }
  printf "私钥路径: "; read -r KEY
  [ -f "$CERT" ] && [ -f "$KEY" ] || { err "证书/私钥文件不存在"; return 1; }
}
tls_json() { [ -n "$CERT" ] && printf '{"enabled":true,"certificate_path":"%s","key_path":"%s"}' "$CERT" "$KEY" || printf '{"enabled":false}'; }

add_vless() { # $1=transport: ws|http|httpupgrade
  local tp=$1 port uuid path tag inb tls
  printf "监听端口: "; read -r port; [[ "$port" =~ ^[0-9]+$ ]] || { err "端口无效"; return; }
  uuid=$(gen_uuid); echo "已生成 UUID: $uuid"
  path="/$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c8 || echo ws)"
  [ "$tp" != tcp ] && { printf "路径 path (回车默认 %s): " "$path"; read -r p2; [ -n "$p2" ] && path=$p2; }
  if [ -n "$NO_TLS" ]; then CERT=""; KEY=""; else ask_tls || return; fi
  tag="vless-$tp-$port"
  tls=$(tls_json)
  inb=$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg path "$path" --argjson tls "$tls" --arg tp "$tp" \
    '{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:""}],
      transport:(if $tp=="ws" then {type:"ws",path:$path} elif $tp=="http" then {type:"http",path:$path,host:[]} else {type:"httpupgrade",path:$path,host:""} end)}
     | if $tls.enabled then .tls=$tls else . end')
  cp "$CFG" "$TMPNEW"; jq --argjson i "$inb" '.inbounds += [$i]' "$CFG" >"$TMPNEW"
  show_link_vless "$port" "$uuid" "$path" "$tp" "$tls"
}
add_vless_reality() {
  local port uuid tag kp priv pub dest dhost dport sni sids inb
  printf "监听端口: "; read -r port; [[ "$port" =~ ^[0-9]+$ ]] || { err "端口无效"; return; }
  uuid=$(gen_uuid); echo "已生成 UUID: $uuid"
  printf "Reality 握手伪装目标 host:port [www.microsoft.com:443]: "; read -r dest; dest=${dest:-www.microsoft.com:443}
  dhost=${dest%:*}; dport=${dest##*:}
  printf "server_name (回车同 %s): " "$dhost"; read -r sni; sni=${sni:-$dhost}
  echo "生成密钥对..."; kp=$("$BIN" generate reality-keypair 2>/dev/null)
  priv=$(echo "$kp" | awk '/PrivateKey/{print $2}'); pub=$(echo "$kp" | awk '/PublicKey/{print $2}')
  [ -n "$priv" ] || { err "密钥生成失败"; return; }
  sids=$(tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c8 || echo 1a2b3c4d)
  tag="vless-reality-$port"
  inb=$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg dh "$dhost" --argjson dp "$dport" --arg sni "$sni" --arg priv "$priv" --arg sid "$sids" \
    '{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],
      tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$dh,server_port:$dp},private_key:$priv,short_id:[$sid]}}}')
  cp "$CFG" "$TMPNEW"; jq --argjson i "$inb" '.inbounds += [$i]' "$CFG" >"$TMPNEW"
  echo; echo "客户端参数 —— private_key 已写入服务端，公钥/short_id 给客户端:"
  echo "  UUID=$uuid  flow=xtls-rprx-vision  security=reality"
  echo "  pbk=$pub  sid=$sids  sni=$sni"
}
add_vmess() { # $1=ws|http|tcp
  local tp=$1 port uuid alter path tag inb tls
  printf "监听端口: "; read -r port; [[ "$port" =~ ^[0-9]+$ ]] || { err "端口无效"; return; }
  uuid=$(gen_uuid); echo "已生成 UUID: $uuid"
  printf "alterId (回车默认0): "; read -r alter; alter=${alter:-0}
  path="/ws"
  if [ "$tp" != tcp ]; then printf "路径 path (回车默认 %s): " "$path"; read -r p2; [ -n "$p2" ] && path=$p2; fi
  if [ -n "$NO_TLS" ]; then CERT=""; KEY=""; else ask_tls || return; fi
  tag="vmess-$tp-$port"
  tls=$(tls_json)
  inb=$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg alter "$alter" --arg path "$path" --argjson tls "$tls" --arg tp "$tp" \
    '{type:"vmess",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,alterId:($alter|tonumber)}]}
     | if $tp=="tcp" then . else .transport=(if $tp=="ws" then {type:"ws",path:$path} elif $tp=="http" then {type:"http",path:$path,host:[]} else {type:"httpupgrade",path:$path,host:""} end) end
     | if $tls.enabled then .tls=$tls else . end')
  cp "$CFG" "$TMPNEW"; jq --argjson i "$inb" '.inbounds += [$i]' "$CFG" >"$TMPNEW"
  show_link_vmess "$port" "$uuid" "$path" "$tp" "$tls"
}
add_cloudflared() {
  local tok tag inb out sel; TMPNEW2=$(mktemp)
  printf "Cloudflare Tunnel Token (零信任里创建): "; read -r tok
  [ -n "$tok" ] || { err "token 不能为空"; return; }
  tag="cf-tunnel-$(date +%s | tail -c5)"
  inb=$(jq -n --arg tag "$tag" --arg tok "$tok" '{type:"cloudflared",tag:$tag,token:$tok,ha_connections:3}')
  cp "$CFG" "$TMPNEW"; jq --argjson i "$inb" '.inbounds += [$i]' "$CFG" >"$TMPNEW"
  echo "隧道流量去向:"; echo "  [1] direct 直连回源(默认)"
  local outs; outs=$(jq -r '[.outbounds[]?|select(.type!="direct")|.tag]|join(",")' "$CFG")
  [ -n "$outs" ] && { echo "  [2] 转给已有出口: $outs"; }
  printf "选择 [1]: "; read -r sel
  if [ "$sel" = 2 ] && [ -n "$outs" ]; then
    printf "出口 tag: "; read -r out
    jq --arg t "$tag" --arg o "$out" '.route = ((.route // {}) | .rules = ((.rules // []) + [{inbound:$t,outbound:$o}]))' "$TMPNEW" >"$TMPNEW2" && mv "$TMPNEW2" "$TMPNEW"
  fi
  ok "已添加 cloudflared 入口 tag=$tag"
}
add_socks() {
  local port listen user pass tag inb
  printf "监听端口: "; read -r port; [[ "$port" =~ ^[0-9]+$ ]] || { err "端口无效"; return; }
  printf "监听地址 [127.0.0.1，回车默认；公网填 0.0.0.0]: "; read -r listen; listen=${listen:-127.0.0.1}
  printf "用户名 (回车=无认证): "; read -r user
  tag="socks-$port"
  if [ -n "$user" ]; then
    printf "密码: "; read -rs pass; echo
    inb=$(jq -n --arg tag "$tag" --argjson port "$port" --arg l "$listen" --arg u "$user" --arg p "$pass" \
      '{type:"socks",tag:$tag,listen:$l,listen_port:$port,users:[{username:$u,password:$p}]}')
  else
    inb=$(jq -n --arg tag "$tag" --argjson port "$port" --arg l "$listen" '{type:"socks",tag:$tag,listen:$l,listen_port:$port}')
  fi
  [ "$listen" != 127.0.0.1 ] && [ -z "$user" ] && warn "公网无认证 socks，强烈建议加用户名密码!"
  cp "$CFG" "$TMPNEW"; jq --argjson i "$inb" '.inbounds += [$i]' "$CFG" >"$TMPNEW"
  ok "已添加 socks 入口 socks5://$([ -n "$user" ] && echo "$user:***@")$listen:$port"
}
add_http_in() {
  local port listen user pass tag inb
  printf "监听端口: "; read -r port; [[ "$port" =~ ^[0-9]+$ ]] || { err "端口无效"; return; }
  printf "监听地址 [127.0.0.1]: "; read -r listen; listen=${listen:-127.0.0.1}
  printf "用户名 (回车=无认证): "; read -r user
  tag="http-$port"
  if [ -n "$user" ]; then printf "密码: "; read -rs pass; echo
    inb=$(jq -n --arg tag "$tag" --argjson port "$port" --arg l "$listen" --arg u "$user" --arg p "$pass" \
      '{type:"http",tag:$tag,listen:$l,listen_port:$port,users:[{username:$u,password:$p}]}')
  else inb=$(jq -n --arg tag "$tag" --argjson port "$port" --arg l "$listen" '{type:"http",tag:$tag,listen:$l,listen_port:$port}'); fi
  cp "$CFG" "$TMPNEW"; jq --argjson i "$inb" '.inbounds += [$i]' "$CFG" >"$TMPNEW"
  ok "已添加 http 入口 $listen:$port"
}

# ---------- 客户端链接展示 ----------
show_link_vless() {
  local port=$1 uuid=$2 path=$3 tp=$4 tls=$5 ip sec="" epath
  ip=$(server_ip)
  [ "$tls" != '{"enabled":false}' ] && sec="&security=tls"
  epath=${path//\//%2F}
  echo; echo "客户端链接 (IP 用 $ip，域名请自行替换):"
  echo "  vless://$uuid@${ip:-<服务器IP>}:$port?encryption=none$sec&type=$tp&path=$epath#sbox-$tp-$port"
}
show_link_vmess() {
  local port=$1 uuid=$2 path=$3 tp=$4 tls=$5 ip net tlson=tls j
  ip=$(server_ip); net=$tp; [ "$tp" = tcp ] && net=none
  [ "$tls" = '{"enabled":false}' ] && tlson=none
  j=$(jq -cn --arg uuid "$uuid" --arg add "${ip:-<服务器IP>}" --argjson port "$port" --arg net "$net" --arg path "$path" --arg tls "$tlson" \
    '{v:"2",ps:"sbox-vmess",add:$add,port:$port,id:$uuid,aid:"0",scy:"auto",net:$net,type:"none",host:"",path:(if $net=="none" then "" else $path end),tls:$tls}')
  echo; echo "客户端链接:"; echo "  vmess://$(printf '%s' "$j" | base64 | tr -d '\n')"
}

# ---------- 菜单页面 ----------
m_add() {
  echo "${C}请选择协议:${N}"
  cat <<'EOF'
  1) VLESS-WS-TLS        2) VLESS-WS (无TLS,套CDN/隧道)
  3) VLESS-H2-TLS        4) VLESS-HTTPUpgrade-TLS
  5) VLESS-REALITY       6) VMESS-TCP
  7) VMESS-WS-TLS        8) VMESS-WS (无TLS)
  9) VMESS-HTTP-TLS     10) Cloudflare-Tunnel
 11) Socks 入口         12) HTTP 入口
  0) 返回
EOF
  printf "请选择 [0-12]: "; read -r op; TMPNEW=$(mktemp)
  case $op in
    1) add_vless ws;; 2) NO_TLS=1; add_vless ws; NO_TLS=;; 3) add_vless http;; 4) add_vless httpupgrade;;
    5) add_vless_reality;; 6) NO_TLS=1; add_vmess tcp; NO_TLS=;; 7) add_vmess ws;; 8) NO_TLS=1; add_vmess ws; NO_TLS=;;
    9) add_vmess http;; 10) add_cloudflared;; 11) add_socks;; 12) add_http_in;; 0) return;;
    *) err "无效"; return;; esac
  [ -s "$TMPNEW" ] && { apply_cfg; pause; }; rm -f "$TMPNEW" "$TMPNEW2"
}
m_change() {
  ask_idx || return
  echo "当前:"; jq ".inbounds[$IDX]" "$CFG"
  cat <<'EOF'
  1) 改端口   2) 改UUID/用户名   3) 改TLS证书路径   4) 改WS路径
  5) 用编辑器直接改整条   0) 返回
EOF
  printf "请选择 [0-5]: "; read -r op; TMPNEW=$(mktemp)
  case $op in
    1) printf "新端口: "; read -r v; jq --argjson i "$IDX" --argjson v "$v" '.inbounds[$i].listen_port=$v' "$CFG" >"$TMPNEW";;
    2) t=$(jq -r ".inbounds[$IDX].type" "$CFG")
       if [ "$t" = vmess ] || [ "$t" = vless ]; then printf "新UUID (回车重新生成): "; read -r v; [ -z "$v" ] && v=$(gen_uuid)
         jq --argjson i "$IDX" --arg v "$v" '.inbounds[$i].users[0].uuid=$v' "$CFG" >"$TMPNEW"
       else printf "新用户名: "; read -r u; printf "新密码: "; read -rs p; echo
         jq --argjson i "$IDX" --arg u "$u" --arg p "$p" '.inbounds[$i].users[0].user=$u | .inbounds[$i].users[0].password=$p' "$CFG" >"$TMPNEW"; fi;;
    3) printf "证书路径: "; read -r c; printf "私钥路径: "; read -r k
       jq --argjson i "$IDX" --arg c "$c" --arg k "$k" '.inbounds[$i].tls={enabled:true,certificate_path:$c,key_path:$k}' "$CFG" >"$TMPNEW";;
    4) printf "新path: "; read -r v; jq --argjson i "$IDX" --arg v "$v" '.inbounds[$i].transport.path=$v' "$CFG" >"$TMPNEW";;
    5) jq ".inbounds[$IDX]" "$CFG" > /tmp/sbox-inb.json
       ${EDITOR:-vi} /tmp/sbox-inb.json && jq --argjson i "$(cat /tmp/sbox-inb.json)" --argjson x "$IDX" '.inbounds[$x]=$i' "$CFG" >"$TMPNEW";;
    0) return;; *) err "无效"; return;; esac
  [ -s "$TMPNEW" ] && { apply_cfg; pause; }; rm -f "$TMPNEW"
}
# ---------- 查看配置卡片 ----------
reality_pub() { # 从 x25519 私钥(base64url) 推导公钥，需要 openssl
  local priv=$1 pk8 raw_hex
  command -v openssl >/dev/null 2>&1 || { echo "(需安装openssl才能推导)"; return; }
  pk8=$(printf '%s=' "$priv" | tr '_-' '/+')
  raw_hex=$(printf '%s' "$pk8" | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "${#raw_hex}" = 64 ] || { echo "?"; return; }
  printf "$(printf '302e020100300506032b656e04220420%s' "$raw_hex" | sed 's/../\\x&/g')" \
    | openssl pkey -inform der -pubout -outform der 2>/dev/null | tail -c 32 | base64 | tr -d '=\n' | tr '/+' '_-'
}
urlenc() { printf '%s' "$1" | sed 's|/|%2F|g; s|?|%3F|g; s|#|%23|g; s|&|%26|g; s| |%20|g'; }

card() { # $1 = 0基索引
  local i=$1 t tag port ip uuid flow tp path host sec sni sid priv pbk ha url user pass l
  t=$(jq -r ".inbounds[$i].type" "$CFG")
  tag=$(jq -r ".inbounds[$i].tag // \"-\"" "$CFG")
  port=$(jq -r ".inbounds[$i].listen_port // \"-\"" "$CFG")
  l=$(jq -r ".inbounds[$i].listen // \"-\"" "$CFG")
  ip=$(server_ip); ip=${ip:-<服务器IP>}
  f() { printf "  %s%-22s%s = %s\n" "$Y" "$1" "$N" "$2"; }
  echo "${C}---------- ${tag} ----------${N}"
  f "协议 (protocol)" "$t"
  f "地址 (address)" "$ip"
  case $t in
    vless|vmess|socks|http)
      f "端口 (port)" "$port"
      f "监听 (listen)" "$l";;
  esac
  case $t in
    vless)
      uuid=$(jq -r ".inbounds[$i].users[0].uuid" "$CFG")
      flow=$(jq -r ".inbounds[$i].users[0].flow // \"\"" "$CFG")
      tp=$(jq -r ".inbounds[$i].transport.type // \"tcp\"" "$CFG")
      path=$(jq -r ".inbounds[$i].transport.path // \"\"" "$CFG")
      sec=none
      [ "$(jq -r ".inbounds[$i].tls.enabled // false" "$CFG")" = true ] && sec=tls
      if [ "$(jq -r ".inbounds[$i].tls.reality.enabled // false" "$CFG")" = true ]; then
        sec=reality
        sni=$(jq -r ".inbounds[$i].tls.server_name // \"\"" "$CFG")
        sid=$(jq -r ".inbounds[$i].tls.reality.short_id[0] // \"\"" "$CFG")
        priv=$(jq -r ".inbounds[$i].tls.reality.private_key" "$CFG")
        pbk=$(reality_pub "$priv")
      fi
      f "用户ID (id)" "$uuid"
      [ -n "$flow" ] && f "流控 (flow)" "$flow"
      f "传输协议 (network)" "$tp"
      f "传输层安全 (TLS)" "$sec"
      [ "$sec" != none ] && [ -n "$sni" ] && f "SNI (serverName)" "$sni"
      [ "$sec" = reality ] && { f "指纹 (Fingerprint)" "chrome"; f "公钥 (Public key)" "$pbk"; f "short_id" "$sid"; }
      [ "$tp" != tcp ] && [ -n "$path" ] && f "路径 (path)" "$path"
      # URL
      if [ "$sec" = reality ]; then
        url="vless://$uuid@$ip:$port?encryption=none&security=reality&flow=$flow&type=$tp&sni=$sni&pbk=$pbk&sid=$sid&fp=chrome#$tag"
      else
        url="vless://$uuid@$ip:$port?encryption=none&security=$sec&type=$tp&path=$(urlenc "$path")#$tag"
      fi
      ;;
    vmess)
      uuid=$(jq -r ".inbounds[$i].users[0].uuid" "$CFG")
      aid=$(jq -r ".inbounds[$i].users[0].alterId // 0" "$CFG")
      tp=$(jq -r ".inbounds[$i].transport.type // \"tcp\"" "$CFG")
      path=$(jq -r ".inbounds[$i].transport.path // \"\"" "$CFG")
      sec=none; [ "$(jq -r ".inbounds[$i].tls.enabled // false" "$CFG")" = true ] && sec=tls
      f "用户ID (id)" "$uuid"
      f "额外ID (alterId)" "$aid"
      f "传输协议 (network)" "$tp"
      f "传输层安全 (TLS)" "$sec"
      [ "$tp" != tcp ] && f "路径 (path)" "$path"
      j=$(jq -cn --arg uuid "$uuid" --arg add "$ip" --argjson port "$port" --arg net "$tp" --arg path "$path" --arg tls "$sec" --arg aid "$aid" --arg ps "$tag" \
        '{v:"2",ps:$ps,add:$add,port:$port,id:$uuid,aid:$aid,scy:"auto",net:$net,type:"none",host:"",path:(if $net=="tcp" then "" else $path end),tls:$tls}')
      url="vmess://$(printf '%s' "$j" | base64 | tr -d '\n')"
      ;;
    socks)
      user=$(jq -r ".inbounds[$i].users[0].username // \"\"" "$CFG")
      pass=$(jq -r ".inbounds[$i].users[0].password // \"\"" "$CFG")
      [ -n "$user" ] && { f "认证 (auth)" "$user"; url="socks5://$user:$pass@$ip:$port"; } || url="socks5://$ip:$port"
      f "认证用户" "${user:-无}"
      ;;
    http)
      user=$(jq -r ".inbounds[$i].users[0].username // \"\"" "$CFG")
      pass=$(jq -r ".inbounds[$i].users[0].password // \"\"" "$CFG")
      [ -n "$user" ] && url="http://$user:$pass@$ip:$port" || url="http://$ip:$port"
      f "认证用户" "${user:-无}"
      ;;
    cloudflared)
      ha=$(jq -r ".inbounds[$i].ha_connections // 3" "$CFG")
      f "高可用连接 (HA)" "$ha"
      f "Token" "$(jq -r ".inbounds[$i].token" "$CFG" | cut -c1-12)...(已隐藏)"
      url="流量经 Cloudflare 边缘进入，客户端连你绑定的域名即可（无需本机端口）"
      ;;
    *) url="" ;;
  esac
  echo "${C}----- 链接 (URL) -----${N}"
  echo "  $url"
  echo "${C}----- END -----${N}"
}
m_view() {
  local cnt n i
  cnt=$(jq '(.inbounds//[])|length' "$CFG")
  [ "$cnt" = 0 ] && { warn "还没有配置，先去[1]添加"; return; }
  list_inbounds
  printf "查看序号 (0=全部): "; read -r n
  if [ "$n" = 0 ]; then for ((i=0;i<cnt;i++)); do card $i; echo; done
  elif [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$cnt" ]; then card $((n-1))
  else err "无效序号"; fi
  pause
}
m_del() {
  ask_idx || return
  tag=$(jq -r ".inbounds[$IDX].tag // \"\"" "$CFG")
  printf "确认删除 [%s]? [y/N]: " "$tag"; read -r r; [ "$r" = y ] || return
  TMPNEW=$(mktemp)
  jq --argjson i "$IDX" --arg t "$tag" 'del(.inbounds[$i])
     | .route = ((.route // {}) | .rules = ((.rules // []) | map(select(((.inbound // "") | tostring) != $t))))' "$CFG" >"$TMPNEW"
  apply_cfg; pause; rm -f "$TMPNEW"
}
m_run() {
  cat <<'EOF'
  1) 启动   2) 停止   3) 重启   4) 状态
  5) 最近50行日志   6) 清空日志   0) 返回
EOF
  printf "请选择 [0-6]: "; read -r op
  case $op in ""|*[!0-6]*) return;; esac
  case $op in
    1) svc start;; 2) svc stop;; 3) svc restart;;
    4) svc status;; 5) tail -50 "$LOGF" 2>/dev/null || journalctl -u sbox -n 50 --no-pager;;
    6) : >"$LOGF" 2>/dev/null; ok "日志已清空";; esac
  pause
}
m_update() {
  local url="$DLBASE-$A"
  curl -fsIL --retry 2 --max-time 15 "$url" >/dev/null 2>&1 || url="$DLBASE"   # 无架构后缀文件则回退
  printf "从 %s 重新下载覆盖，配置保留。继续? [y/N]: " "$url"; read -r r
  [ "$r" = y ] || return
  TMPB=$(mktemp); svc stop
  if curl -fL --retry 3 -o "$TMPB" "$url"; then
    chmod 755 "$TMPB"; mv "$TMPB" "$BIN"; ok "已更新"; svc start
    "$BIN" version | head -1
  else err "下载失败"; svc start; fi
  rm -f "$TMPB"
}
m_uninstall() {
  printf "%s确认卸载 sbox? 服务与程序将删除，配置目录 %s 默认保留。输入 YES 继续: %s" "$R" "$ETC" "$N"; read -r r
  [ "$r" = YES ] || { warn "已取消"; return; }
  svc stop 2>/dev/null; svc disable 2>/dev/null
  rm -f /usr/local/bin/sbox /etc/systemd/system/sbox.service /etc/init.d/sbox
  [ -d /run/systemd/system ] && systemctl daemon-reload
  rm -rf /opt/sbox
  printf "连同 %s 一起删除? [y/N]: " "$ETC"; read -r r; [ "$r" = y ] && rm -rf "$ETC"
  ok "卸载完成"
}
m_other() {
  cat <<'EOF'
  1) 校验当前配置   2) 生成 UUID   3) 生成 Reality 密钥对
  4) 恢复最近备份   5) 列出备份   0) 返回
EOF
  printf "请选择 [0-5]: "; read -r op
  case $op in
    1) "$BIN" check -c "$CFG" && ok "配置有效";;
    2) gen_uuid;;
    3) "$BIN" generate reality-keypair;;
    4) b=$(ls -t "$ETC/backup"/config.*.json 2>/dev/null | head -1); [ -n "$b" ] && { cp "$b" "$CFG"; ok "已恢复 $b"; svc restart; } || warn "无备份"
       ;;
    5) ls -lt "$ETC/backup"/ 2>/dev/null | tail -10;; *) return;; esac
  pause
}
m_about() {
  echo "${C}sbox${N} —— sing-box 精简定制版管理面板"
  "$BIN" version 2>/dev/null | head -4
  echo "系统: $(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")  架构: $A"
  echo "服务: $(command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && echo systemd || { command -v rc-service >/dev/null 2>&1 && echo OpenRC || echo manual; })"
  echo "入口数: $(jq '(.inbounds//[])|length' "$CFG")  出口数: $(jq '(.outbounds//[])|length' "$CFG")"
  echo "监听: $( { ss -tln 2>/dev/null || true; netstat -tln 2>/dev/null || true; } | grep -oE ':[0-9]+ ' | tr -d ': ' | sort -un | tr '\n' ' ')"
  pause
}

main_menu() {
  load_cfg
  while true; do
    clear 2>/dev/null
    echo "${C}══════════════ sbox 管理面板 ══════════════${N}"
    printf "%s1)%s 添加配置\n%s2)%s 更改配置\n%s3)%s 查看配置\n%s4)%s 删除配置\n%s5)%s 运行管理\n%s6)%s 更新\n%s7)%s 卸载\n%s8)%s 其他\n%s9)%s 关于\n" \
      $G $N $G $N $G $N $G $N $G $N $G $N $G $N $G $N $G $N
    echo; printf "请选择 %s[%s1-9%s]%s: " "$Y" "$R" "$Y" "$N"; read -r op || { echo; break; }
    case $op in
      1) m_add;; 2) m_change;; 3) m_view;; 4) m_del;; 5) m_run;;
      6) m_update;; 7) m_uninstall;; 8) m_other;; 9) m_about;;
      0|q) echo "bye"; break;; *) err "无效选择"; sleep 1;; esac
  done
}

if [ -z "${SBOX_SOURCE_ONLY:-}" ]; then main_menu; fi
SBOXMENU_EOF
chmod 755 /usr/local/bin/sbox

# ---------- 注册自启服务 ----------
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  cat > /etc/systemd/system/sbox.service <<'EOF'
[Unit]
Description=sbox (sing-box trimmed)
Documentation=file:/usr/local/bin/sbox
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/sbox/sbox run -D /etc/sbox -c /etc/sbox/config.json
WorkingDirectory=/etc/sbox
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sbox >/dev/null 2>&1 && echo ">> systemd 服务已注册 (systemctl {status|restart} sbox)"
  systemctl restart sbox 2>/dev/null && sleep 1 && echo ">> 服务已启动" || true
elif command -v rc-update >/dev/null 2>&1; then
  cat > /etc/init.d/sbox <<'EOF'
#!/sbin/openrc-run
description="sbox (sing-box trimmed)"
command="/opt/sbox/sbox"
command_args="run -D /etc/sbox -c /etc/sbox/config.json"
command_background="yes"
pidfile="/run/sbox.pid"
retry="TERM/10/KILL/5"
output_log="/var/log/sbox.log"
error_log="/var/log/sbox.log"
EOF
  chmod 755 /etc/init.d/sbox
  rc-update add sbox default >/dev/null 2>&1 && echo ">> OpenRC 服务已注册并设自启 (rc-service sbox status)"
  rc-service sbox restart 2>/dev/null && echo ">> 服务已启动" || true
else
  echo "⚠ 未检测到 systemd/OpenRC，菜单[5]运行管理将以 nohup 手动模式工作"
fi

echo
echo "=============================================="
echo " ✔ 安装完成！终端输入  sbox  打开管理面板"
echo "   二进制: $LIB_DIR/sbox    菜单: /usr/local/bin/sbox"
echo "   配置:   $ETC_DIR/config.json  日志: $LOGF"
echo "   备份:   $ETC_DIR/backup/"
echo "=============================================="
