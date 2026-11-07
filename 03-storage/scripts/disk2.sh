#!/bin/bash
# disk2.sh — отключает и возвращает диск массива block3-disk2 (SATA-порт 2) для 9.2.
#   disk2.sh off   ждёт, пока VM выключится, отключает диск и запускает VM
#   disk2.sh on    возвращает тот же образ в работающую VM (порт hot-pluggable)
# Из-за снапшота на порту стоит разностный образ {...}.vdi, а не сам block3-disk2.vdi:
# его UUID запоминается в disk2.uuid и при возврате подключается он же.
set -u
VM=server
F=$(dirname "$(readlink -f "$0")")/disk2.uuid
st() { VBoxManage showvminfo "$VM" --machinereadable | sed -n 's/^VMState="\(.*\)"$/\1/p'; }

case ${1:-} in
  off)
    for i in $(seq 1 60); do [[ $(st) == poweroff ]] && break; echo "жду выключения VM ($(st))"; sleep 2; done
    [[ $(st) == poweroff ]] || { echo "VM так и не выключилась — сделайте poweroff на сервере"; exit 1; }
    U=$(VBoxManage showvminfo "$VM" --machinereadable | sed -n 's/^"SATA-ImageUUID-2-0"="\(.*\)"$/\1/p')
    [[ -n $U ]] || { echo "на порту 2 диска нет — уже отключён?"; exit 1; }
    echo "$U" > "$F"
    VBoxManage storageattach "$VM" --storagectl SATA --port 2 --device 0 --medium none || exit 1
    echo "диск отключён ($U), запускаю VM"
    for i in $(seq 1 10); do
      sleep 2
      VBoxManage startvm "$VM" --type headless 2>/dev/null && exit 0
    done
    echo "VM не запустилась"; exit 1 ;;
  on)
    [[ -s $F ]] || { echo "нет $F — диск не отключали через disk2.sh off"; exit 1; }
    VBoxManage storageattach "$VM" --storagectl SATA --port 2 --device 0 --type hdd --medium "$(cat "$F")" || exit 1
    echo "диск возвращён ($(cat "$F"))" ;;
  *)
    echo "использование: $0 off|on"; exit 2 ;;
esac
