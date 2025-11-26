#!/bin/bash
# === main.sh (to'liq tuzatilgan versiya: APT Update Notifier) ===
# Muammolar hal qilindi: DBus to'g'ri topiladi, faqat kerak bo'lganda upgrade, log tozalash.

DEFAULT_USER=$(whoami)

# Zarur paketlar o'rnatish (agar yo'q bo'lsa)
echo "[*] Zarur paketlar o‘rnatilmoqda..."
sudo apt update -y
sudo apt install -y libnotify-bin gir1.2-notify-0.7 dbus-x11 gzip gnome-terminal gedit xterm nano vim

SCRIPT_PATH="/usr/local/bin/apt-update-notify.sh"
USER_FILE="/etc/apt-update-user.txt"  # Foydalanuvchi nomini saqlash uchun fayl

echo "[*] $USER_FILE ga foydalanuvchi nomi saqlanmoqda..."
echo "$DEFAULT_USER" | sudo tee "$USER_FILE" > /dev/null

echo "[*] $SCRIPT_PATH yaratilmoqda..."
sudo tee "$SCRIPT_PATH" > /dev/null <<'EOF'
#!/bin/bash

# Foydalanuvchi nomini o'qish (cron uchun muhim)
USER_NAME=$(sudo cat /etc/apt-update-user.txt 2>/dev/null || echo "$DEFAULT_USER")
USER_ID=$(id -u "$USER_NAME" 2>/dev/null || echo 1000)  # Default UID 1000
LOG_FILE="/var/log/apt-cron.log"
MAX_SIZE=$((5 * 1024 * 1024))  # 5 MB

export DISPLAY=:0
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus"

# --- Log hajmini tekshirish va tozalash ---
if [ -f "$LOG_FILE" ] && [ $(sudo stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -ge $MAX_SIZE ]; then
    TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
    sudo gzip -c "$LOG_FILE" > "/var/log/apt-cron-$TIMESTAMP.log.gz"
    sudo truncate -s 0 "$LOG_FILE"
    echo "Log arxivlandi: /var/log/apt-cron-$TIMESTAMP.log.gz" | sudo tee -a "$LOG_FILE" > /dev/null
fi

echo "========== $(date '+%Y-%m-%d %H:%M:%S') ==========" | sudo tee -a "$LOG_FILE" > /dev/null

# --- Yangilashlarni tekshirish (faqat kerak bo'lganda upgrade) ---
echo "APT yangilanishlari tekshirilmoqda..." | sudo tee -a "$LOG_FILE"
sudo apt update 2>&1 | sudo tee -a "$LOG_FILE"

UPGRADE_COUNT=$(apt list --upgradable 2>/dev/null | grep -v "^Listing" | grep -v '^$' | wc -l)

if [ "$UPGRADE_COUNT" -gt 0 ]; then
    echo "✅ $UPGRADE_COUNT ta yangilanish topildi, yangilanmoqda..." | sudo tee -a "$LOG_FILE"
    sudo apt upgrade -y 2>&1 | sudo tee -a "$LOG_FILE"
    sudo apt autoremove -y 2>&1 | sudo tee -a "$LOG_FILE"
    sudo apt autoclean -y 2>&1 | sudo tee -a "$LOG_FILE"
    UPDATE_MESSAGE="✅ $UPGRADE_COUNT ta paket yangilandi"
    ICON="software-update-available"
else
    echo "⚠️ Yangilanish topilmadi (Not Upgrading: $UPGRADE_COUNT)." | sudo tee -a "$LOG_FILE"
    UPDATE_MESSAGE="⚠️ Yangilanish topilmadi"
    ICON="dialog-information"
fi

# --- DBus sessiyasini tekshirish va bildirishnoma yuborish ---
if [ -S "/run/user/$USER_ID/bus" ]; then
    echo "DBus ($USER_NAME) topildi, bildirishnoma yuborilmoqda..." | sudo tee -a "$LOG_FILE"
    
    # sudo -u bilan foydalanuvchi sifatida notification yuborish
    NOTIF_ID=$(sudo -u "$USER_NAME" env DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
    gdbus call --session \
    --dest org.freedesktop.Notifications \
    --object-path /org/freedesktop/Notifications \
    --method org.freedesktop.Notifications.Notify \
    "APT Updater" 0 "$ICON" "🔔 APT Yangilash" \
    "$UPDATE_MESSAGE — $(date '+%H:%M:%S')" \
    "['open_log', 'Logni ochish']" \
    "{}" 10000 | awk '{print $2}' | tr -d ',)')

    if [ -n "$NOTIF_ID" ] && [ "$NOTIF_ID" != "()" ]; then
        echo "Bildirishnoma yuborildi, ID: $NOTIF_ID" | sudo tee -a "$LOG_FILE"
    else
        echo "XATO: Bildirishnoma yuborilmadi! (Sessiya ochiqmi?)" | sudo tee -a "$LOG_FILE"
    fi
else
    echo "⚠️ Foydalanuvchi ($USER_NAME) uchun DBus sessiya topilmadi — Notification chiqarilmadi. (Login qiling.)" | sudo tee -a "$LOG_FILE"
fi
EOF

sudo chmod +x "$SCRIPT_PATH"

# Cron job qo'shish — har 1 soatda (faqat yangilanish bo'lsa upgrade qiladi)
echo "[*] Cron job qo‘shilmoqda (root)..."
( sudo crontab -l 2>/dev/null | grep -v "apt-update-notify.sh"; echo "0 * * * * /usr/local/bin/apt-update-notify.sh" ) | sudo crontab -

# === Monitor skripti (bildirishnoma tugmasini qabul qilish uchun) ===
MONITOR_SCRIPT="$HOME/.local/bin/apt-notify-monitor.sh"
AUTOSTART_DIR="$HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/apt-notify-monitor.desktop"

echo "[*] Log ochish tugmasini qabul qiluvchi skript yaratilmoqda..."
mkdir -p "$HOME/.local/bin"
mkdir -p "$AUTOSTART_DIR"

tee "$MONITOR_SCRIPT" > /dev/null <<'EOF'
#!/bin/bash

USER_NAME=$(logname 2>/dev/null || echo $USER)
LOG_FILE="/var/log/apt-cron.log"

# Logni ochish funksiyasi (terminal yoki editor)
open_log_file() {
    if command -v gnome-terminal >/dev/null 2>&1; then
        gnome-terminal --title="APT Log" -- bash -c "sudo tail -n 50 -f '$LOG_FILE'; exec bash"
    elif command -v xterm >/dev/null 2>&1; then
        xterm -title "APT Log" -e "sudo tail -n 50 -f '$LOG_FILE'; read -p 'Davom etish uchun Enter bosing...'"
    elif command -v gedit >/dev/null 2>&1; then
        sudo -u "$USER_NAME" gedit "$LOG_FILE" &
    else
        notify-send "Log fayli" "Terminalda: sudo tail -n 50 /var/log/apt-cron.log"
    fi
}

# gdbus monitor — doimiy ishlaydi (notification tugmasini kutadi)
gdbus monitor --session --dest org.freedesktop.Notifications |
while read -r line; do
    if echo "$line" | grep -q "ActionInvoked"; then
        ACTION=$(echo "$line" | awk -F'"' '{print $2}')
        if [ "$ACTION" = "open_log" ]; then
            open_log_file
        fi
    fi
done
EOF

chmod +x "$MONITOR_SCRIPT"

# Autostart desktop fayli
tee "$AUTOSTART_FILE" > /dev/null <<EOF
[Desktop Entry]
Type=Application
Name=APT Notify Monitor
Exec=$MONITOR_SCRIPT
Comment=APT yangilash logini ochish uchun tugmani kuzatadi
Terminal=false
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF

# Log ruxsatlarini sozlash
sudo touch "$LOG_FILE"
sudo chmod 644 "$LOG_FILE"
sudo chown root:root "$LOG_FILE"

echo "[✅] O‘rnatish yakunlandi! Har 1 soatda yangilash tekshiriladi."
echo ""
echo "[ℹ️] Eslatmalar:"
echo "  - Bildirishnoma uchun foydalanuvchi sessiyasi ochiq bo'lsin (ekranda login qiling)."
echo "  - Monitor ishga tushishi uchun: tizimni restart qiling yoki '$MONITOR_SCRIPT' ni qo'lda bajaring."
echo "  - sudo visudo ga qo'shing (log o'qish uchun, xavfsiz):"
echo "    $DEFAULT_USER ALL=(ALL) NOPASSWD: /usr/bin/tail /usr/bin/less /usr/bin/nano /usr/bin/vim"
echo ""
echo "[🧪] Test qilish: sudo /usr/local/bin/apt-update-notify.sh"
echo "    Logni ko'rish: sudo tail -f /var/log/apt-cron.log"
