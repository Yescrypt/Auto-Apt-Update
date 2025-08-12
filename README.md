<h1 align="center">🚀 Auto-APT-Update</h1>

<p align="center">
  <b>Debian / Kali / Ubuntu uchun avtomatik APT yangilanish tekshiruv skripti</b>  
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Bash-Script-green?style=flat-square">
  <img src="https://img.shields.io/badge/Platform-Linux-blue?style=flat-square">
  <img src="https://img.shields.io/badge/License-MIT-yellow?style=flat-square">
</p>

---

## 📌 Nima qiladi?
✅ Har **1 soatda** APT yangilanishlarini tekshiradi.  
✅ Agar yangilanish bo‘lsa:
- 📜 Paketlar ro‘yxatini **logga yozadi**  
- 🔄 Paketlarni **avtomatik yangilaydi**  
- 📊 Yangilangan paketlar sonini **xabar beradi**  

✅ Yangilanish yo‘q bo‘lsa ham logga qayd etadi.  
✅ Log fayli **5 MB** dan oshsa — avtomatik arxivlaydi.  
✅ **7 kundan** eski arxivlarni o‘chiradi.  
✅ **Grafik bildirishnoma** chiqaradi (logni ochish tugmasi bilan).  
✅ `"12 packages can be upgraded..."` xabarini ham bildirishnomaga qo‘shadi.  

---

## 🛠 O‘rnatish

Terminalda quyidagi buyruqlarni to‘liq nusxa olib ishga tushiring:

```bash
git clone https://github.com/Yescrypt/Auto-Apt-Update.git
cd Auto-Apt-Update
chmod +x main.sh
./main.sh
