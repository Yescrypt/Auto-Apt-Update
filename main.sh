#!/bin/bash

# === Foydalanuvchi nomini so'rash ===
read -rp "Yangilash bildirishnomalari qaysi user uchun o‘rnatilsin? [kali]: " USER_NAME
USER_NAME=${USER_NAME:-coder}

# === Notification paketlarini o‘rnatish ===
echo "[*] Zarur paketlar o‘rnatilmoqda..."
sudo apt update
sudo apt install -y libnotify-bin gir1.2-notify-0.7 dbus-x11 gzip

# === apt-update-notify.sh faylini yaratish ===
SCRIPT_PATH="/usr/local/bin/apt-update-notify.sh"
echo "[*] $SCRIPT_PATH yaratilmoqda..."

sudo tee "$SCRIPT_PATH" > /dev/null <<EOF
#!/bin/bash

LOG_FILE="/var/log/apt-cron.log"
MAX_SIZE=\$((5 * 1024 * 1024))  # 5 MB
USER_NAME="$USER_NAME"
USER_ID=\$(id -u "\$USER_NAME")

# --- Log hajmi tekshirish va arxivlash ---
if [ -f "\$LOG_FILE" ] && [ \$(stat -c%s "\$LOG_FILE") -ge \$MAX_SIZE ]; then
    TIMESTAMP=\$(date '+%Y%m%d-%H%M%S')
    sudo gzip -c "\$LOG_FILE" > "/var/log/apt-cron-\$TIMESTAMP.log.gz"
    echo "Log arxivlandi: /var/log/apt-cron-\$TIMESTAMP.log.gz"
    sudo truncate -s 0 "\$LOG_FILE"
fi

# 7 kundan eski arxivlarni o‘chirish
sudo find /var/log/ -maxdepth 1 -name "apt-cron-*.log.gz" -type f -mtime +7 -exec rm -f {} \;

# Sana va vaqtni logga yozish
echo "========== \$(date '+%Y-%m-%d %H:%M:%S') ==========" | sudo tee -a "\$LOG_FILE" > /dev/null

# --- Yangilash ---
sudo apt update | sudo tee -a "\$LOG_FILE" > /dev/null
UPGRADE_LIST=\$(apt list --upgradable 2>/dev/null | grep -v "^Listing")
UPGRADE_COUNT=\$(echo "\$UPGRADE_LIST" | grep -v '^$' | wc -l)

if [ "\$UPGRADE_COUNT" -gt 0 ]; then
    echo "Yangilanish kerak bo‘lgan paketlar (\$UPGRADE_COUNT):" | sudo tee -a "\$LOG_FILE" > /dev/null
    echo "\$UPGRADE_LIST" | sudo tee -a "\$LOG_FILE" > /dev/null
    echo "" | sudo tee -a "\$LOG_FILE" > /dev/null

    sudo apt upgrade -y | sudo tee -a "\$LOG_FILE" > /dev/null
    sudo apt autoremove -y | sudo tee -a "\$LOG_FILE" > /dev/null

    UPDATE_MESSAGE="✅ \$UPGRADE_COUNT ta paket yangilandi"
    ICON="software-update-available"
else
    UPDATE_MESSAGE="⚠️ Yangilanish topilmadi"
    ICON="dialog-information"
fi

# --- Bildirishnoma chiqarish ---
sudo -u "\$USER_NAME" DISPLAY=:0 \
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$USER_ID/bus \
gdbus call --session \
--dest org.freedesktop.Notifications \
--object-path /org/freedesktop/Notifications \
--method org.freedesktop.Notifications.Notify \
"APT Updater" 0 "\$ICON" "🔔 APT Yangilash" \
"\$UPDATE_MESSAGE — \$(date '+%H:%M:%S')" \
"['default', 'Logni ochish']" \
{} 10000 &

# --- Bosilganda logni ochish ---
sudo -u "\$USER_NAME" DISPLAY=:0 \
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$USER_ID/bus \
dbus-monitor "interface='org.freedesktop.Notifications',member='ActionInvoked'" |
while read -r line; do
    if echo "\$line" | grep -q "default"; then
        if command -v gedit >/dev/null 2>&1; then
            gedit +999999 "\$LOG_FILE" &
        elif command -v mousepad >/dev/null 2>&1; then
            mousepad "\$LOG_FILE" &
        else
            x-terminal-emulator -e less +G "\$LOG_FILE" &
        fi
        break
    fi
done
EOF

# Faylga ruxsat berish
sudo chmod +x "$SCRIPT_PATH"

# === Crontab ga qo'shish ===
echo "[*] Crontab sozlanmoqda..."
( crontab -l 2>/dev/null; echo "*/60 * * * * $SCRIPT_PATH >> /var/log/apt-cron.log 2>&1" ) | crontab -

echo "[✓] O‘rnatish tugadi!"
echo "   Script: $SCRIPT_PATH"
echo "   Crontab: */60 daqiqada ishga tushadi"
