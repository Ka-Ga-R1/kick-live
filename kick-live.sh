#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"
APP_NAME="Kick 直播中转一键管理脚本"

CONFIG_DIR="/etc/kick-live"
STREAM_DIR="${CONFIG_DIR}/streams"
CONFIG_FILE="${CONFIG_DIR}/config.env"
WEB_ROOT="/var/www/html"
LIVE_ROOT="${WEB_ROOT}/live"
PLAYLIST_FILE="${WEB_ROOT}/playlist.m3u"
WORKER_BIN="/usr/local/bin/kick-live-worker"
MANAGER_BIN="/usr/local/bin/kick-live"
SERVICE_FILE="/etc/systemd/system/kick-live@.service"
NGINX_SITE="/etc/nginx/sites-available/kick-live"
NGINX_ENABLED="/etc/nginx/sites-enabled/kick-live"

DEFAULT_DOMAIN="kick.example.com"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 用户运行。"
        exit 1
    fi
}

validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

validate_channel() {
    local channel="$1"
    [[ "$channel" =~ ^[A-Za-z0-9_-]{1,64}$ ]]
}

validate_name() {
    local name="$1"
    [[ "$name" =~ ^[a-z0-9_-]{1,64}$ ]]
}

pause() {
    echo
    read -r -p "按回车键返回菜单..." _
}

ensure_dirs() {
    mkdir -p "$CONFIG_DIR" "$STREAM_DIR" "$LIVE_ROOT"
    touch "$CONFIG_FILE"
}

load_config() {
    DOMAIN="$DEFAULT_DOMAIN"
    if [ -f "$CONFIG_FILE" ]; then
        while IFS='=' read -r key value; do
            case "$key" in
                DOMAIN) DOMAIN="$value" ;;
            esac
        done < "$CONFIG_FILE"
    fi
    if ! validate_domain "$DOMAIN"; then
        DOMAIN="$DEFAULT_DOMAIN"
    fi
}

load_stream_config() {
    local env_file="$1"
    CHANNEL=""
    NAME=""
    QUALITY_LABEL=""
    TARGET_HEIGHT=""
    TARGET_FPS=""
    while IFS='=' read -r key value; do
        case "$key" in
            CHANNEL) CHANNEL="$value" ;;
            NAME) NAME="$value" ;;
            QUALITY_LABEL) QUALITY_LABEL="$value" ;;
            TARGET_HEIGHT) TARGET_HEIGHT="$value" ;;
            TARGET_FPS) TARGET_FPS="$value" ;;
        esac
    done < "$env_file"
}

save_domain() {
    local domain="$1"
    mkdir -p "$CONFIG_DIR"
    printf 'DOMAIN=%s\n' "$domain" > "$CONFIG_FILE"
    chmod 0644 "$CONFIG_FILE"
}

is_installed() {
    [ -x "$WORKER_BIN" ] && [ -f "$SERVICE_FILE" ] && command -v nginx >/dev/null 2>&1 && command -v ffmpeg >/dev/null 2>&1 && command -v yt-dlp >/dev/null 2>&1
}

service_is_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

env_status() {
    if is_installed; then
        printf "已安装"
    else
        printf "未安装"
    fi
}

nginx_status() {
    if service_is_active nginx; then
        printf "Nginx 已启动"
    else
        printf "Nginx 未启动"
    fi
}

stream_count() {
    find "$STREAM_DIR" -maxdepth 1 -type f -name '*.env' 2>/dev/null | wc -l | tr -d ' '
}

clear_screen() {
    clear 2>/dev/null || true
}

main_menu() {
    ensure_dirs
    load_config
    while true; do
        clear_screen
        cat <<EOF
 ${APP_NAME} [v${VERSION}]

  0. 升级脚本
 ———————————————————————
  1. 安装/更新环境
  2. 卸载环境
 ———————————————————————
  3. 配置域名和 HTTPS
  4. 查看播放列表
 ———————————————————————
  5. 添加直播间
  6. 管理直播间
  7. 生成播放列表
 ———————————————————————
  8. 查看全局状态
  9. 查看实时日志
 10. 清空日志
 ———————————————————————

 环境状态: $(env_status) | $(nginx_status)
 当前域名: ${DOMAIN:-未配置}
 直播间数量: $(stream_count)
 播放列表: https://${DOMAIN:-你的域名}/playlist.m3u

EOF
        read -r -p " 请输入数字 [0-10]: " choice
        case "$choice" in
            0) upgrade_script ;;
            1) install_or_update ;;
            2) uninstall_env ;;
            3) configure_domain_https ;;
            4) show_playlist ;;
            5) add_stream ;;
            6) manage_streams ;;
            7) generate_playlist && pause ;;
            8) show_global_status ;;
            9) view_realtime_logs ;;
            10) clear_logs ;;
            *) echo "请输入 0-10。"; sleep 1 ;;
        esac
    done
}

upgrade_script() {
    ensure_dirs
    if [ -f "$0" ]; then
        cp "$0" "$MANAGER_BIN"
        chmod +x "$MANAGER_BIN"
        echo "脚本已安装/升级到：$MANAGER_BIN"
    else
        echo "无法定位当前脚本文件。"
    fi
    pause
}

install_or_update() {
    ensure_dirs
    echo "正在安装/更新依赖..."
    apt update
    apt install -y nginx ffmpeg python3 python3-pip certbot python3-certbot-nginx ca-certificates curl

    if id -u www-data >/dev/null 2>&1; then
        chown -R www-data:www-data "$LIVE_ROOT" 2>/dev/null || true
    fi

    if python3 -m pip --version >/dev/null 2>&1; then
        python3 -m pip install -U yt-dlp --break-system-packages
    else
        apt install -y yt-dlp
    fi

    write_worker
    write_systemd_template
    cp "$0" "$MANAGER_BIN"
    chmod +x "$MANAGER_BIN" "$WORKER_BIN"
    systemctl daemon-reload
    systemctl enable --now nginx
    echo "环境安装/更新完成。以后可运行：kick-live"
    pause
}

write_worker() {
    cat > "$WORKER_BIN" <<'EOF'
#!/usr/bin/env bash
set -u

NAME="${1:-}"
CONFIG_FILE="/etc/kick-live/streams/${NAME}.env"

if ! [[ "$NAME" =~ ^[a-z0-9_-]{1,64}$ ]] || [ ! -f "$CONFIG_FILE" ]; then
    echo "Stream config not found: ${CONFIG_FILE}"
    exit 1
fi

CHANNEL=""
QUALITY_LABEL=""
TARGET_HEIGHT=""
TARGET_FPS=""

while IFS='=' read -r key value; do
    case "$key" in
        CHANNEL) CHANNEL="$value" ;;
        QUALITY_LABEL) QUALITY_LABEL="$value" ;;
        TARGET_HEIGHT) TARGET_HEIGHT="$value" ;;
        TARGET_FPS) TARGET_FPS="$value" ;;
    esac
done < "$CONFIG_FILE"

if [ -z "$CHANNEL" ]; then
    echo "Invalid stream config: ${CONFIG_FILE}"
    exit 1
fi

OUT_DIR="/var/www/html/live/${NAME}"
KICK_URL="https://kick.com/${CHANNEL}"
YTDLP_LOG="/tmp/kick-${NAME}-ytdlp.log"

mkdir -p "$OUT_DIR"
chown -R www-data:www-data "$OUT_DIR" 2>/dev/null || true

choose_format() {
    local json_file selected
    json_file="$(mktemp)"

    if ! yt-dlp -J "$KICK_URL" > "$json_file" 2>"$YTDLP_LOG"; then
        rm -f "$json_file"
        echo "best"
        return
    fi

    selected="$(python3 - "$json_file" "${TARGET_HEIGHT:-}" "${TARGET_FPS:-}" <<'PY'
import json
import sys

path, target_height, target_fps = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(path, 'r', encoding='utf-8') as fh:
        data = json.load(fh)
except Exception:
    print('best')
    raise SystemExit

formats = []
for item in data.get('formats') or []:
    format_id = str(item.get('format_id') or '')
    height = item.get('height')
    fps = item.get('fps')
    vcodec = item.get('vcodec')
    if not format_id or height is None or vcodec == 'none':
        continue
    try:
        height = int(height)
    except Exception:
        continue
    try:
        fps_value = int(round(float(fps or 0)))
    except Exception:
        fps_value = 0
    formats.append((format_id, height, fps_value))

if not formats:
    print('best')
    raise SystemExit

try:
    wanted_height = int(target_height or 0)
except Exception:
    wanted_height = 0
try:
    wanted_fps = int(target_fps or 0)
except Exception:
    wanted_fps = 0

if wanted_height:
    same_height = [f for f in formats if f[1] == wanted_height]
    if same_height and wanted_fps:
        same_fps = [f for f in same_height if f[2] == wanted_fps]
        if same_fps:
            print(sorted(same_fps, key=lambda x: (x[2], x[1]), reverse=True)[0][0])
            raise SystemExit
    if same_height:
        print(sorted(same_height, key=lambda x: (x[2], x[1]), reverse=True)[0][0])
        raise SystemExit

lower = [f for f in formats if wanted_height and f[1] < wanted_height]
if lower:
    print(sorted(lower, key=lambda x: (x[1], x[2]), reverse=True)[0][0])
else:
    print(sorted(formats, key=lambda x: (x[1], x[2]), reverse=True)[0][0])
PY
)"

    rm -f "$json_file"
    if [ -n "$selected" ]; then
        echo "$selected"
    else
        echo "best"
    fi
}

while true; do
    rm -f "$OUT_DIR"/*.m3u8 "$OUT_DIR"/*.ts "$OUT_DIR"/*.tmp

    FORMAT_ID="$(choose_format)"
    STREAM_URL="$(yt-dlp -f "$FORMAT_ID/best" -g "$KICK_URL" 2>"$YTDLP_LOG" | head -n 1)"

    if [ -z "$STREAM_URL" ]; then
        echo "[$(date -Is)] 未获取到直播流：${CHANNEL}，30 秒后重试"
        sleep 30
        continue
    fi

    echo "[$(date -Is)] 启动拉流：${CHANNEL} -> ${NAME} | ${QUALITY_LABEL:-自动最佳} | format=${FORMAT_ID}"

    ffmpeg -hide_banner -loglevel warning -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 10 -i "$STREAM_URL" -map 0:v:0 -map 0:a:0 -c copy -f hls -hls_time 4 -hls_list_size 6 -hls_delete_threshold 2 -hls_flags delete_segments+omit_endlist+temp_file -hls_segment_filename "$OUT_DIR/segment_%05d.ts" "$OUT_DIR/index.m3u8"

    echo "[$(date -Is)] ffmpeg 已退出：${CHANNEL}，10 秒后重试"
    sleep 10
done
EOF
}

write_systemd_template() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Kick Live HLS Restream %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WORKER_BIN} %i
Restart=always
RestartSec=10
User=www-data
Group=www-data
NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

uninstall_env() {
    echo "此操作会停止所有 kick-live 服务，并删除脚本生成的配置、直播目录和播放列表。"
    read -r -p "确认卸载？输入 YES 继续: " confirm
    [ "$confirm" = "YES" ] || { echo "已取消。"; pause; return; }

    while IFS= read -r env_file; do
        name="$(basename "$env_file" .env)"
        validate_name "$name" || continue
        systemctl disable --now "kick-live@${name}" 2>/dev/null || true
    done < <(find "$STREAM_DIR" -maxdepth 1 -type f -name '*.env' 2>/dev/null)

    rm -f "$WORKER_BIN" "$MANAGER_BIN" "$SERVICE_FILE" "$NGINX_ENABLED" "$NGINX_SITE" "$PLAYLIST_FILE"
    if [ "$CONFIG_DIR" = "/etc/kick-live" ]; then
        rm -rf -- "$CONFIG_DIR"
    fi
    if [ "$LIVE_ROOT" = "/var/www/html/live" ]; then
        rm -rf -- "$LIVE_ROOT"
    fi
    systemctl daemon-reload
    systemctl reload nginx 2>/dev/null || true
    echo "卸载完成。依赖软件 nginx/ffmpeg/yt-dlp 未删除。"
    pause
}

configure_domain_https() {
    ensure_dirs
    load_config
    read -r -p "请输入域名 [${DOMAIN:-$DEFAULT_DOMAIN}]: " input_domain
    input_domain="${input_domain:-${DOMAIN:-$DEFAULT_DOMAIN}}"
    if ! validate_domain "$input_domain"; then
        echo "域名格式无效。"
        pause
        return
    fi
    save_domain "$input_domain"
    DOMAIN="$input_domain"
    write_nginx_config
    nginx -t
    systemctl reload nginx
    echo "Nginx 配置完成：http://${DOMAIN}/playlist.m3u"
    echo
    read -r -p "是否现在申请/更新 HTTPS 证书？[y/N]: " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        certbot --nginx -d "$DOMAIN"
    fi
    pause
}

write_nginx_config() {
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root ${WEB_ROOT};

    location /live/ {
        types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t ts;
        }

        default_type application/octet-stream;

        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
        add_header Pragma "no-cache" always;
        add_header Expires "0" always;
        add_header Access-Control-Allow-Origin "*" always;

        sendfile on;
        tcp_nopush on;
        tcp_nodelay on;

        try_files \$uri =404;
    }

    location = /playlist.m3u {
        types {
            audio/x-mpegurl m3u;
            application/vnd.apple.mpegurl m3u8;
        }

        add_header Cache-Control "no-cache" always;
        add_header Access-Control-Allow-Origin "*" always;

        try_files \$uri =404;
    }
}
EOF
    ln -sf "$NGINX_SITE" "$NGINX_ENABLED"
    rm -f /etc/nginx/sites-enabled/default
}

show_playlist() {
    load_config
    if [ ! -f "$PLAYLIST_FILE" ]; then
        echo "播放列表不存在，请先生成播放列表。"
    else
        echo "播放列表地址："
        echo "  https://${DOMAIN}/playlist.m3u"
        echo "  http://${DOMAIN}/playlist.m3u"
        echo
        cat "$PLAYLIST_FILE"
    fi
    pause
}

sanitize_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

quality_label() {
    local height="$1"
    local fps="$2"
    local base
    case "$height" in
        2160) base="4K" ;;
        1440) base="2K" ;;
        1080) base="1080P" ;;
        720) base="720P" ;;
        480) base="480P" ;;
        360) base="360P" ;;
        240) base="240P" ;;
        *) base="${height}P" ;;
    esac
    if [ "${fps:-0}" -ge 50 ]; then
        echo "${base} ${fps}帧"
    else
        echo "$base"
    fi
}

select_quality() {
    local channel="$1"
    local temp_json temp_options selected count line option
    temp_json="$(mktemp)"
    temp_options="$(mktemp)"

    echo "正在解析清晰度，请稍候..."
    if ! yt-dlp -J "https://kick.com/${channel}" > "$temp_json" 2>/tmp/kick-quality.log; then
        rm -f "$temp_json" "$temp_options"
        echo "无法解析清晰度。可能是主播未开播或频道不存在。"
        return 1
    fi

    python3 - "$temp_json" > "$temp_options" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    data = json.load(fh)

seen = set()
items = []
for item in data.get('formats') or []:
    height = item.get('height')
    fps = item.get('fps')
    vcodec = item.get('vcodec')
    if height is None or vcodec == 'none':
        continue
    try:
        height = int(height)
    except Exception:
        continue
    try:
        fps = int(round(float(fps or 0)))
    except Exception:
        fps = 0
    key = (height, fps)
    if key in seen:
        continue
    seen.add(key)
    items.append(key)

for height, fps in sorted(items, key=lambda x: (x[0], x[1]), reverse=True):
    print(f'{height}|{fps}')
PY

    count="$(wc -l < "$temp_options" | tr -d ' ')"
    if [ "$count" = "0" ]; then
        rm -f "$temp_json" "$temp_options"
        echo "未找到可用清晰度。"
        return 1
    fi

    echo
    echo "可用清晰度："
    local index=1
    while IFS='|' read -r height fps; do
        printf " %2d. %s\n" "$index" "$(quality_label "$height" "$fps")"
        index=$((index + 1))
    done < "$temp_options"
    echo

    while true; do
        read -r -p "请选择清晰度 [1-${count}]: " selected
        if [[ "$selected" =~ ^[0-9]+$ ]] && [ "$selected" -ge 1 ] && [ "$selected" -le "$count" ]; then
            line="$(sed -n "${selected}p" "$temp_options")"
            break
        fi
        echo "输入无效。"
    done

    height="${line%%|*}"
    fps="${line##*|}"
    label="$(quality_label "$height" "$fps")"

    SELECTED_HEIGHT="$height"
    SELECTED_FPS="$fps"
    SELECTED_LABEL="$label"
    rm -f "$temp_json" "$temp_options"
}

add_stream() {
    ensure_dirs
    read -r -p "请输入 Kick 频道名: " channel
    if [ -z "$channel" ]; then
        echo "频道名不能为空。"
        pause
        return
    fi
    if ! validate_channel "$channel"; then
        echo "频道名只能包含字母、数字、下划线和短横线。"
        pause
        return
    fi

    default_name="$(sanitize_name "$channel")"
    read -r -p "请输入本地名称/目录名 [${default_name}]: " name
    name="${name:-$default_name}"
    name="$(sanitize_name "$name")"

    if ! validate_name "$name"; then
        echo "本地名称无效。"
        pause
        return
    fi

    if [ -f "${STREAM_DIR}/${name}.env" ]; then
        echo "直播间已存在：$name"
        pause
        return
    fi

    if ! select_quality "$channel"; then
        pause
        return
    fi

    mkdir -p "${LIVE_ROOT}/${name}"
    {
        printf 'CHANNEL=%s\n' "$channel"
        printf 'NAME=%s\n' "$name"
        printf 'QUALITY_LABEL=%s\n' "$SELECTED_LABEL"
        printf 'TARGET_HEIGHT=%s\n' "$SELECTED_HEIGHT"
        printf 'TARGET_FPS=%s\n' "$SELECTED_FPS"
    } > "${STREAM_DIR}/${name}.env"
    chmod 0644 "${STREAM_DIR}/${name}.env"

    chown -R www-data:www-data "${LIVE_ROOT}/${name}" 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable --now "kick-live@${name}"
    generate_playlist
    echo "已添加并启动：${name} | ${channel} | ${SELECTED_LABEL}"
    pause
}

stream_menu_items() {
    find "$STREAM_DIR" -maxdepth 1 -type f -name '*.env' 2>/dev/null | sort | while IFS= read -r env_file; do
        name="$(basename "$env_file" .env)"
        if validate_name "$name"; then
            printf '%s\n' "$env_file"
        fi
    done
}

choose_stream() {
    local files=() index=1 selected env_file name channel label status
    while IFS= read -r env_file; do
        files+=("$env_file")
    done < <(stream_menu_items)

    if [ "${#files[@]}" -eq 0 ]; then
        echo "暂无直播间。"
        return 1
    fi

    echo "请选择直播间："
    for env_file in "${files[@]}"; do
        name="$(basename "$env_file" .env)"
        load_stream_config "$env_file"
        if service_is_active "kick-live@${name}"; then
            status="运行中"
        else
            status="已停止"
        fi
        printf " %2d. %s | %s | %s | %s\n" "$index" "$name" "${CHANNEL:-未知}" "${QUALITY_LABEL:-未知}" "$status"
        index=$((index + 1))
    done
    echo "  0. 返回"
    echo

    while true; do
        read -r -p "请输入数字: " selected
        if [ "$selected" = "0" ]; then
            return 1
        fi
        if [[ "$selected" =~ ^[0-9]+$ ]] && [ "$selected" -ge 1 ] && [ "$selected" -le "${#files[@]}" ]; then
            SELECTED_STREAM="$(basename "${files[$((selected - 1))]}" .env)"
            return 0
        fi
        echo "输入无效。"
    done
}

manage_streams() {
    ensure_dirs
    while true; do
        clear_screen
        if ! choose_stream; then
            pause
            return
        fi
        manage_single_stream "$SELECTED_STREAM"
    done
}

manage_single_stream() {
    local name="$1"
    local env_file="${STREAM_DIR}/${name}.env"
    local choice
    validate_name "$name" || return
    [ -f "$env_file" ] || return
    load_stream_config "$env_file"

    while true; do
        clear_screen
        cat <<EOF
 ${name} | ${CHANNEL} | ${QUALITY_LABEL}

  1. 启动
  2. 停止
  3. 重启
  4. 修改清晰度
  5. 查看状态
  6. 查看日志
  7. 删除直播间
  0. 返回

EOF
        read -r -p " 请输入数字 [0-7]: " choice
        case "$choice" in
            1) systemctl start "kick-live@${name}"; echo "已启动。"; pause ;;
            2) systemctl stop "kick-live@${name}"; echo "已停止。"; pause ;;
            3) systemctl restart "kick-live@${name}"; echo "已重启。"; pause ;;
            4) change_quality "$name"; load_stream_config "$env_file" ;;
            5) systemctl status "kick-live@${name}" --no-pager; pause ;;
            6) journalctl -u "kick-live@${name}" -f ;;
            7) remove_stream "$name"; return ;;
            0) return ;;
            *) echo "输入无效。"; sleep 1 ;;
        esac
    done
}

change_quality() {
    local name="$1"
    local env_file="${STREAM_DIR}/${name}.env"
    validate_name "$name" || { echo "本地名称无效。"; pause; return; }
    load_stream_config "$env_file"
    if ! select_quality "$CHANNEL"; then
        pause
        return
    fi
    {
        printf 'CHANNEL=%s\n' "$CHANNEL"
        printf 'NAME=%s\n' "$name"
        printf 'QUALITY_LABEL=%s\n' "$SELECTED_LABEL"
        printf 'TARGET_HEIGHT=%s\n' "$SELECTED_HEIGHT"
        printf 'TARGET_FPS=%s\n' "$SELECTED_FPS"
    } > "$env_file"
    chmod 0644 "$env_file"
    systemctl restart "kick-live@${name}"
    generate_playlist
    echo "清晰度已修改为：${SELECTED_LABEL}"
    pause
}

remove_stream() {
    local name="$1"
    validate_name "$name" || { echo "本地名称无效，拒绝删除。"; pause; return; }
    echo "将删除直播间：$name"
    read -r -p "确认删除？输入 YES 继续: " confirm
    [ "$confirm" = "YES" ] || { echo "已取消。"; pause; return; }
    systemctl disable --now "kick-live@${name}" 2>/dev/null || true
    rm -f "${STREAM_DIR}/${name}.env"
    if [ "$LIVE_ROOT" = "/var/www/html/live" ]; then
        rm -rf -- "${LIVE_ROOT}/${name}"
    fi
    generate_playlist
    echo "已删除：$name"
    pause
}

generate_playlist() {
    ensure_dirs
    load_config
    mkdir -p "$WEB_ROOT"
    cat > "$PLAYLIST_FILE" <<EOF
#EXTM3U
EOF

    while IFS= read -r env_file; do
        name="$(basename "$env_file" .env)"
        load_stream_config "$env_file"
        cat >> "$PLAYLIST_FILE" <<EOF
#EXTINF:-1 tvg-id="${name}" tvg-name="${CHANNEL}" group-title="Kick",${CHANNEL} - ${QUALITY_LABEL}
https://${DOMAIN}/live/${name}/index.m3u8
EOF
    done < <(stream_menu_items)

    chown www-data:www-data "$PLAYLIST_FILE" 2>/dev/null || true
    echo "播放列表已生成：${PLAYLIST_FILE}"
    echo "地址：https://${DOMAIN}/playlist.m3u"
}

show_global_status() {
    ensure_dirs
    load_config
    echo "环境状态: $(env_status) | $(nginx_status)"
    echo "当前域名: ${DOMAIN}"
    echo "直播间数量: $(stream_count)"
    echo
    while IFS= read -r env_file; do
        name="$(basename "$env_file" .env)"
        load_stream_config "$env_file"
        if service_is_active "kick-live@${name}"; then
            status="运行中"
        else
            status="已停止"
        fi
        if [ -f "${LIVE_ROOT}/${name}/index.m3u8" ]; then
            output="已生成"
        else
            output="未生成"
        fi
        echo "${name} | ${CHANNEL} | ${QUALITY_LABEL} | ${status} | HLS ${output}"
    done < <(stream_menu_items)
    pause
}

view_realtime_logs() {
    ensure_dirs
    if choose_stream; then
        journalctl -u "kick-live@${SELECTED_STREAM}" -f
    fi
    pause
}

clear_logs() {
    echo "systemd journal 不支持只清理单个服务日志。"
    echo "为避免影响整台服务器，脚本不会执行全局日志清理。"
    pause
}

require_root
main_menu
