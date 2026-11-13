#!/bin/bash
# Часть 2а — сервер не грузится, root заблокирован. Запускается первым, потом reboot.
# Поломка случайная: массив не собирается или /backup не монтируется.
D=/root/.b3
[[ $EUID -eq 0 ]] || { echo "нужен root"; exit 1; }
[[ -s $D/boot1 ]] && { echo "2а уже внесена — почини, потом boot-2b.sh"; exit 1; }
exec bash /root/break-storage.sh --boot
