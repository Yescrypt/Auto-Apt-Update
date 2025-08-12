#!/bin/bash

# === User avtomatik aniqlash ===
USER_NAME=$(logname 2>/dev/null || whoami)
USER_ID=$(id -u "$USER_NAME")

# === Zarur paketlar ===
echo "[*] Zarur paketlar o‘rnatilmoqda..."
sudo apt update -y
sudo apt install -y libnotify-bin gir1.2-notify-0.7 dbus-x11 gzip gawk

# === Skript yo‘li ===
SCRIPT_PATH="/usr/local/bin/apt-update-notify.sh"

# === apt-update-notify.sh yaratish ===
echo "[*] $SCRIPT_PATH yaratilmoqda..."
sudo tee "$SCRIPT_PATH" > /dev/null <<EOF
#!/bin/bash

LOG_FILE="/var/log/apt-cron.log"
MAX_SIZE=\$((5 * 1024 * 1024))  # 5 MB
USER_NAME="$USER_NAME"
USER_ID="$USER_ID"

export DISPLAY=:0
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$USER_ID/bus"

# --- Log hajmini tekshirish ---
if [ -f "\$LOG_FILE" ] && [ \$(stat -c%s "\$LOG_FILE") -ge \$MAX_SIZE ]; then
    TIMESTAMP=\$(date '+%Y%m%d-%H%M%S')
    sudo gzip -c "\$LOG_FILE" > "/var/log/apt-cron-\$TIMESTAMP.log.gz"
    sudo truncate -s 0 "\$LOG_FILE"
fi

# 7 kundan eski arxivlarni o‘chirish
sudo find /var/log/ -maxdepth 1 -name "apt-cron-*.log.gz" -type f -mtime +7 -exec rm -f {} \;

echo "========== \$(date '+%Y-%m-%d %H:%M:%S') ==========" | sudo tee -a "\$LOG_FILE" > /dev/null

# --- Yangilash ---
sudo apt update -y | sudo tee -a "\$LOG_FILE" > /dev/null
UPGRADE_LIST=\$(apt list --upgradable 2>/dev/null | grep -v "^Listing")
UPGRADE_COUNT=\$(echo "\$UPGRADE_LIST" | grep -v '^$' | wc -l)

if [ "\$UPGRADE_COUNT" -gt 0 ]; then
    echo "Yangilanish kerak bo‘lgan paketlar (\$UPGRADE_COUNT):" | sudo tee -a "\$LOG_FILE" > /dev/null
    echo "\$UPGRADE_LIST" | sudo tee -a "\$LOG_FILE" > /dev/null
    sudo apt upgrade -y | sudo tee -a "\$LOG_FILE" > /dev/null
    sudo apt autoremove -y | sudo tee -a "\$LOG_FILE" > /dev/null
    UPDATE_MESSAGE="✅ \$UPGRADE_COUNT ta paket yangilandi"
    ICON="software-update-available"
else
    UPDATE_MESSAGE="⚠️ Yangilanish topilmadi"
    ICON="dialog-information"
fi

# --- Notification chiqarish va tugmani ishlatish ---
if [ -S "/run/user/\$USER_ID/bus" ]; then
    USER_ENV="DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$USER_ID/bus"

    NOTIF_OUTPUT=\$(sudo -u "\$USER_NAME" env \$USER_ENV \
    gdbus call --session \
    --dest org.freedesktop.Notifications \
    --object-path /org/freedesktop/Notifications \
    --method org.freedesktop.Notifications.Notify \
    "APT Updater" 0 "\$ICON" "🔔 APT Yangilash" \
    "\$UPDATE_MESSAGE — \$(date '+%H:%M:%S')" \
    "['default', 'Logni ochish']" \
    {} 10000)

    NOTIF_ID=\$(echo "\$NOTIF_OUTPUT" | awk '{print \$2}' | tr -d ',)')

    # Tugma bosilishini kuzatish (faqat bitta marta ishlaydi)
    sudo -u "\$USER_NAME" env \$USER_ENV \
    gdbus monitor --session --dest org.freedesktop.Notifications |
    while read -r line; do
        if echo "\$line" | grep -q "ActionInvoked" && echo "\$line" | grep -q "\$NOTIF_ID"; then
            ACTION=\$(echo "\$line" | awk -F'"' '{print \$2}')
            if [ "\$ACTION" = "default" ]; then
                x-terminal-emulator -e "sudo less +G \$LOG_FILE" &
                pkill -P \$$
                break
            fi
        fi
    done &

else
    echo "⚠️ \$USER_NAME uchun DBus sessiya topilmadi — Notification chiqarilmadi." | sudo tee -a "\$LOG_FILE" > /dev/null
fi
EOF

# === Bajarish huquqi ===
sudo chmod +x "$SCRIPT_PATH"

# === root cron ga qo‘shish ===
echo "[*] Cron job qo‘shilmoqda (root)..."
( sudo crontab -l 2>/dev/null; echo "0 * * * * /usr/local/bin/apt-update-notify.sh" ) | sudo crontab -

echo "[✅] O‘rnatish yakunlandi. Har 1 soatda yangilash tekshiriladi."
