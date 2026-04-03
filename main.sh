#!/bin/bash
# ============================================================
#  APT Update Notifier — Xavfsizlik tekshiruvi o'tkazilgan versiya
#  - APT + Flatpak + Snap yangilash
#  - Disk bo'sh joy tekshiruvi (yangilashdan oldin)
#  - Desktop notification (DBus orqali)
#  - Log tozalash: 5 kundan eski qatorlar avtomatik o'chiriladi
#  - Har soatda cron orqali avtomatik ishlaydi
#  - Monitor: notification tugmasini bosganda logni ochadi
#
#  ISHLATISH: bash main.sh   (sudo kerak emas)
# ============================================================

set -euo pipefail

# ─── RANGLAR ─────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[ℹ]${NC}  $*"; }
success() { echo -e "${GREEN}[✅]${NC} $*"; }
warning() { echo -e "${YELLOW}[⚠]${NC}  $*"; }
die()     { echo -e "${RED}[❌]${NC} $*" >&2; exit 1; }

# ─── LOADER (spinner) ─────────────────────────────────────────
_spin_pid=""
spinner_start() {
    local msg="$1"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    (
        local i=0
        while true; do
            printf "\r${CYAN}[${frames[$i]}]${NC}  %s" "$msg"
            i=$(( (i+1) % ${#frames[@]} ))
            sleep 0.12
        done
    ) &
    _spin_pid=$!
    disown "$_spin_pid" 2>/dev/null || true
}
spinner_stop() {
    [ -z "$_spin_pid" ] && return
    kill "$_spin_pid" 2>/dev/null || true
    wait "$_spin_pid" 2>/dev/null || true
    _spin_pid=""
    printf "\r\033[2K"
}

# ─── XAVFSIZLIK TEKSHIRUVLARI ────────────────────────────────

# [SEC-1] Root sifatida ishga tushirilmasin
# Sabab: root HOME=/root — monitor va autostart noto'g'ri joyga yoziladi
#        USER_FILE ga "root" saqlanib, cron notification yubora olmaydi
if [ "$(id -u)" -eq 0 ]; then
    die "Skriptni root sifatida ishga tushirmang!\nIshlatish: bash main.sh"
fi

# [SEC-2] sudo mavjudligini tekshirish
command -v sudo &>/dev/null || die "sudo topilmadi."

# ─── SOZLAMALAR ──────────────────────────────────────────────
DEFAULT_USER="$(whoami)"   # root emasligi yuqorida tekshirildi
MIN_FREE_DISK_MB=500
LOG_FILE="/var/log/apt-cron.log"
LOG_MAX_DAYS=5
SCRIPT_PATH="/usr/local/bin/apt-update-notify.sh"
USER_FILE="/etc/apt-update-user.txt"
MONITOR_SCRIPT="$HOME/.local/bin/apt-notify-monitor.sh"
AUTOSTART_DIR="$HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/apt-notify-monitor.desktop"

# [SEC-3] Foydalanuvchi nomi faqat xavfsiz belgilardan iborat bo'lsin
# Sabab: nom keyinchalik "sudo -u $user_name" ga beriladi
if [[ ! "$DEFAULT_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    die "Noto'g'ri foydalanuvchi nomi: '$DEFAULT_USER'"
fi

# ─── 1. ZARUR PAKETLARNI O'RNATISH ───────────────────────────
info "Zarur paketlar tekshirilmoqda..."
NEEDED_PKGS=(libnotify-bin dbus-x11 dbus-user-session gzip xterm)
MISSING=()
for pkg in "${NEEDED_PKGS[@]}"; do
    dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    spinner_start "O'rnatilmoqda: ${MISSING[*]} ..."
    sudo apt-get update -qq
    sudo apt-get install -y "${MISSING[@]}" -qq
    spinner_stop
fi
success "Paketlar tayyor."

# ─── 2. FOYDALANUVCHI NOMINI SAQLASH ────────────────────────
info "Foydalanuvchi: $DEFAULT_USER"
echo "$DEFAULT_USER" | sudo tee "$USER_FILE" > /dev/null
# [SEC-4] USER_FILE faqat root yoza/o'qiy olsin
sudo chmod 600 "$USER_FILE"
sudo chown root:root "$USER_FILE"

# ─── 3. ASOSIY YANGILASH SKRIPTINI YOZISH ───────────────────
spinner_start "Yangilash skripti yozilmoqda..."
sudo tee "$SCRIPT_PATH" > /dev/null <<'EOF'
#!/bin/bash
# === Har soatda root cron chaqiradigan asosiy skript ===

set -uo pipefail

LOG_FILE="/var/log/apt-cron.log"
LOG_MAX_DAYS=5
MIN_FREE_DISK_MB=500
USER_FILE="/etc/apt-update-user.txt"

# ── Log yozish ───────────────────────────────────────────────
log() {
    printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
        | tee -a "$LOG_FILE" > /dev/null
}

# ── Foydalanuvchi nomini xavfsiz o'qish ─────────────────────
get_user() {
    local u
    u=$(cat "$USER_FILE" 2>/dev/null || true)
    # [SEC-5] Injection oldini olish — faqat xavfsiz nom qabul qilinadi
    if [[ ! "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        log "⛔ USER_FILE ichidagi nom xavfli: '$u'"
        exit 1
    fi
    echo "$u"
}

# ── Desktop notification ─────────────────────────────────────
notify() {
    local title="$1" body="$2" icon="${3:-dialog-information}" actions="${4:-}"
    local user_name user_id bus_path

    user_name=$(get_user)
    user_id=$(id -u "$user_name" 2>/dev/null || echo "")

    # [SEC-6] user_id faqat raqam bo'lishi kerak
    if [[ ! "$user_id" =~ ^[0-9]+$ ]]; then
        log "⚠ Noto'g'ri user ID — notification bekor qilindi."
        return
    fi

    bus_path="/run/user/$user_id/bus"
    # [SEC-7] DBus socket mavjudligini tekshirish
    if [ -S "$bus_path" ]; then
        sudo -u "$user_name" env \
            DISPLAY=:0 \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$bus_path" \
            gdbus call --session \
            --dest org.freedesktop.Notifications \
            --object-path /org/freedesktop/Notifications \
            --method org.freedesktop.Notifications.Notify \
            "APT Updater" 0 "$icon" "$title" "$body" \
            "[$actions]" "{}" 12000 > /dev/null 2>&1 || true
        log "🔔 Notification: $title"
    else
        log "⚠ DBus topilmadi ($user_name) — notification chiqarilmadi."
    fi
}

# ── Log tozalash ─────────────────────────────────────────────
log_cleanup() {
    [ ! -f "$LOG_FILE" ] && return
    local cutoff tmp
    cutoff=$(date -d "$LOG_MAX_DAYS days ago" '+%Y-%m-%d' 2>/dev/null || echo "")
    [ -z "$cutoff" ] && return
    # [SEC-8] mktemp — /tmp da oldindan taxminlab bo'lmaydigan nom
    tmp=$(mktemp /tmp/apt-log-clean.XXXXXX)
    awk -v cut="$cutoff" '
        /^[0-9]{4}-[0-9]{2}-[0-9]{2}/ { keep = ($1 >= cut) }
        keep { print }
    ' "$LOG_FILE" > "$tmp"
    cp "$tmp" "$LOG_FILE"
    rm -f "$tmp"
    log "🧹 Log tozalandi: $LOG_MAX_DAYS kundan eski yozuvlar o'chirildi."
}

# ── Disk bo'sh joyini tekshirish ─────────────────────────────
check_disk() {
    local free_mb
    free_mb=$(df /usr --output=avail -BM | tail -1 | tr -d 'M ')
    # [SEC-9] Faqat raqam — df chiqishida kutilmagan belgi bo'lsa xavfsiz
    free_mb="${free_mb//[^0-9]/}"
    free_mb="${free_mb:-0}"
    log "💾 Bo'sh disk joyi: ${free_mb} MB"
    if [ "$free_mb" -lt "$MIN_FREE_DISK_MB" ]; then
        log "⛔ Disk joyi yetarli emas! Yangilash bekor qilindi."
        notify "⛔ Disk joyi yetarli emas" \
               "Bo'sh joy: ${free_mb} MB (kerak: ${MIN_FREE_DISK_MB} MB)" \
               "dialog-error"
        exit 1
    fi
}

# ── Xavfsiz son yordamchisi ───────────────────────────────────
safe_count() {
    local val="${1//[^0-9]/}"
    echo "${val:-0}"
}

# ── APT yangilash ─────────────────────────────────────────────
run_apt() {
    log "─── APT yangilanishlar tekshirilmoqda ───"
    apt-get update -qq 2>&1 | tee -a "$LOG_FILE" > /dev/null

    local raw count
    raw=$(apt list --upgradable 2>/dev/null) || raw=""
    count=$(safe_count "$(echo "$raw" | awk '/^Listing/{next} NF{c++} END{print c+0}')")

    if [ "$count" -gt 0 ]; then
        log "📦 $count ta APT paketi yangilanmoqda..."
        # [SEC-10] DEBIAN_FRONTEND=noninteractive — interaktiv so'rov yo'q
        DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y \
            -o Dpkg::Options::="--force-confold" \
            2>&1 | tee -a "$LOG_FILE" > /dev/null
        apt-get autoremove -y 2>&1 | tee -a "$LOG_FILE" > /dev/null
        apt-get autoclean   2>&1 | tee -a "$LOG_FILE" > /dev/null
        log "✅ APT: $count ta paket yangilandi."
    else
        log "ℹ APT: Yangilanish yo'q."
    fi
    echo "$count"
}

# ── Flatpak yangilash ─────────────────────────────────────────
run_flatpak() {
    if ! command -v flatpak &>/dev/null; then
        echo "skip"; return
    fi
    log "─── Flatpak yangilanmoqda ───"
    local raw count
    raw=$(flatpak remote-ls --updates 2>/dev/null) || raw=""
    count=$(safe_count "$(echo "$raw" | awk 'NF{c++} END{print c+0}')")
    # [SEC-11] --system: root cron uchun to'g'ri flag
    flatpak update --system -y 2>&1 | tee -a "$LOG_FILE" > /dev/null || true
    log "✅ Flatpak: $count ta yangilandi."
    echo "$count"
}

# ── Snap yangilash ────────────────────────────────────────────
run_snap() {
    if ! command -v snap &>/dev/null; then
        echo "skip"; return
    fi
    log "─── Snap yangilanmoqda ───"
    local raw count
    raw=$(snap refresh --list 2>/dev/null) || raw=""
    count=$(safe_count "$(echo "$raw" | awk 'NR>1 && NF{c++} END{print c+0}')")
    snap refresh 2>&1 | tee -a "$LOG_FILE" > /dev/null || true
    log "✅ Snap: $count ta yangilandi."
    echo "$count"
}

# ── Xavfsizlik patch hisoboti ─────────────────────────────────
security_count() {
    local raw n
    raw=$(apt list --upgradable 2>/dev/null) || raw=""
    n=$(safe_count "$(echo "$raw" | awk 'tolower($0) ~ /security/{c++} END{print c+0}')")
    echo "$n"
}

# ═══════════════════════════════════════════════════════════════
#  ASOSIY JARAYON
# ═══════════════════════════════════════════════════════════════

# [SEC-12] Skript faqat root sifatida ishlashi kerak
if [ "$(id -u)" -ne 0 ]; then
    echo "Bu skript root tomonidan chaqirilishi kerak." >&2
    exit 1
fi

log "══════════ Yangilash sessiyasi boshlandi ══════════"

log_cleanup
check_disk

SEC=$(security_count)
APT_COUNT=$(run_apt)
FLATPAK_COUNT=$(run_flatpak)
SNAP_COUNT=$(run_snap)

TIMESTAMP=$(date '+%H:%M:%S')
MSG=""

if [ "$APT_COUNT" -gt 0 ]; then
    MSG+="📦 APT: ${APT_COUNT} ta paket yangilandi\n"
else
    MSG+="📦 APT: Yangilanish yo'q\n"
fi
[ "$FLATPAK_COUNT" != "skip" ] && [ "$FLATPAK_COUNT" -gt 0 ] && \
    MSG+="🖥  Flatpak: ${FLATPAK_COUNT} ta yangilandi\n"
[ "$SNAP_COUNT" != "skip" ] && [ "$SNAP_COUNT" -gt 0 ] && \
    MSG+="⚙️  Snap: ${SNAP_COUNT} ta yangilandi\n"
[ "$SEC" -gt 0 ] && MSG+="🔐 Xavfsizlik: ${SEC} ta patch\n"

FINAL_MSG=$(printf "%b" "$MSG" | sed '/^[[:space:]]*$/d')

if [ "$APT_COUNT" -gt 0 ] || \
   { [ "$FLATPAK_COUNT" != "skip" ] && [ "$FLATPAK_COUNT" -gt 0 ]; } || \
   { [ "$SNAP_COUNT"    != "skip" ] && [ "$SNAP_COUNT"    -gt 0 ]; }; then
    notify "✅ Yangilash yakunlandi — $TIMESTAMP" \
           "$FINAL_MSG" \
           "software-update-available" \
           "'open_log', '📋 Logni ochish'"
else
    notify "ℹ Tekshirildi — $TIMESTAMP" \
           "Hech qanday yangilanish topilmadi." \
           "dialog-information" \
           "'open_log', '📋 Logni ochish'"
fi

log "══════════ Sessiya yakunlandi ══════════"
EOF

# [SEC-13] Skript ruxsatlari: faqat root o'zgartira olsin
sudo chmod 755 "$SCRIPT_PATH"
sudo chown root:root "$SCRIPT_PATH"
spinner_stop
success "Yangilash skripti tayyor."

# ─── 4. LOG FAYLI RUXSATLARI ─────────────────────────────────
# [SEC-14] root yozadi (644) — foydalanuvchi faqat o'qiy oladi
sudo touch "$LOG_FILE"
sudo chmod 644 "$LOG_FILE"
sudo chown root:root "$LOG_FILE"

# ─── 5. CRON JOB ─────────────────────────────────────────────
spinner_start "Cron job sozlanmoqda..."
EXISTING_CRON=$(sudo crontab -l 2>/dev/null || true)
NEW_CRON=$(echo "$EXISTING_CRON" | grep -v "apt-update-notify.sh" || true)
printf '%s\n%s\n' "$NEW_CRON" "0 * * * * $SCRIPT_PATH" | \
    grep -v '^[[:space:]]*$' | sudo crontab -
spinner_stop
success "Cron job qo'shildi: har soatda :00 da."

# ─── 6. MONITOR SKRIPT ───────────────────────────────────────
spinner_start "Monitor skript yaratilmoqda..."
mkdir -p "$HOME/.local/bin" "$AUTOSTART_DIR"

# [SEC-15] Monitor root huquqisiz ishlaydi — faqat log o'qish va terminal
tee "$MONITOR_SCRIPT" > /dev/null <<'MONEOF'
#!/bin/bash
# === APT Notify Monitor — foydalanuvchi sessiyasida ishlaydi ===
# Root huquqi yo'q. Faqat log o'qiydi va terminal ochadi.

LOG_FILE="/var/log/apt-cron.log"

# [SEC-16] Faqat bitta nusxa ishlaydi — uid bilan unique lock
LOCK="/tmp/apt-notify-monitor-$(id -u).lock"
exec 9>"$LOCK"
flock -n 9 || exit 0

open_log() {
    # [SEC-17] exec bash qo'shilmadi — foydalanuvchi buyruq kirita olmasin
    local cmd="tail -n 80 -f '$LOG_FILE'"
    if command -v gnome-terminal &>/dev/null; then
        gnome-terminal --title="APT Log" -- bash -c "$cmd" &
    elif command -v xfce4-terminal &>/dev/null; then
        xfce4-terminal --title="APT Log" -e "bash -c \"$cmd\"" &
    elif command -v xterm &>/dev/null; then
        xterm -title "APT Log" -e "bash -c \"$cmd\"" &
    elif command -v konsole &>/dev/null; then
        konsole --title "APT Log" -e "bash -c \"$cmd\"" &
    fi
}

# [SEC-18] dbus-monitor faqat ActionInvoked signalini tinglaydi
#          to'liq session trafigini emas — minimal ruxsat
dbus-monitor --session \
    "type='signal',interface='org.freedesktop.Notifications',member='ActionInvoked'" \
    2>/dev/null | \
while IFS= read -r line; do
    # [SEC-19] grep -F (fixed string) — regex injection oldini olish
    if echo "$line" | grep -qF '"open_log"'; then
        open_log
    fi
done
MONEOF

# [SEC-20] Monitor faqat egasi bajara olsin
chmod 700 "$MONITOR_SCRIPT"
spinner_stop
success "Monitor skript tayyor."

# ─── 7. AUTOSTART ────────────────────────────────────────────
spinner_start "Autostart sozlanmoqda..."
tee "$AUTOSTART_FILE" > /dev/null <<EOF
[Desktop Entry]
Type=Application
Name=APT Notify Monitor
Exec=$MONITOR_SCRIPT
Comment=APT notification tugmasini kuzatadi
Terminal=false
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
chmod 644 "$AUTOSTART_FILE"
spinner_stop
success "Autostart sozlandi."

# ─── 8. XULOSA ───────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
success "O'rnatish muvaffaqiyatli yakunlandi!"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
echo "  📌 Cron:     Har soatda  →  $SCRIPT_PATH"
echo "  📋 Log:      tail -f $LOG_FILE"
echo "  🔔 Monitor:  $MONITOR_SCRIPT"
echo "  💾 Min disk: ${MIN_FREE_DISK_MB} MB"
echo "  🧹 Log:      ${LOG_MAX_DAYS} kundan eski yozuvlar o'chiriladi"
echo ""
echo "  🧪 Sinab ko'rish: sudo $SCRIPT_PATH"
echo ""

# Eski monitor nusxasini o'ldirib, yangisini ishga tushirish
pkill -f "apt-notify-monitor" 2>/dev/null || true
sleep 0.3
spinner_start "Monitor ishga tushirilmoqda..."
nohup "$MONITOR_SCRIPT" > /dev/null 2>&1 &
_mpid=$!
sleep 0.6
spinner_stop
success "Monitor ishga tushdi (PID: $_mpid)"