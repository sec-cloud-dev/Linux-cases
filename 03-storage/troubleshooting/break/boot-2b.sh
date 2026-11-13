#!/bin/bash
# Часть 2б — сервер не грузится, пароль root неизвестен. Только после починенной 2а, потом reboot.
# Поломка — вторая из двух; root получает случайный пароль, который нигде не сохраняется.
D=/root/.b3
[[ $EUID -eq 0 ]] || { echo "нужен root"; exit 1; }
[[ -s $D/boot1 ]] || { echo "сначала boot-2a.sh и её починка"; exit 1; }
exec bash /root/break-storage.sh --boot
