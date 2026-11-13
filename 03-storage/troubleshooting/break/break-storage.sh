#!/bin/bash
# break-storage.sh — трабалшутинг блока 3.
# Часть 1: вносит 9–10 поломок: на каждом из 8 слоёв одна случайная, на 1–2 слоях — вторая.
# Хотя бы две проявляются только после перезагрузки, хотя бы одна пара стоит друг на друге
# (вторую не видно, пока не починена первая).
# Часть 2 (загрузка): --boot, затем перезагрузка; второй --boot — вторая поломка + пароль root.
# Ничего не печатает, кроме итоговой строки. Ошибки внесения — в /root/.b3/err (если файл не пуст, скрипт
# печатает их вместо «внесено»), набор — /root/.b3/sel (base64, чтобы не прочитать случайно).
#   B3_ONLY="f4 f13"  — внести только эти (для проверки самих поломок)
#   B3_FORCE=1        — не проверять, что стенд в эталоне
set -u
D=/root/.b3; VERIFY=/root/verify-storage.sh
MD=/dev/md/data; LV=/dev/vg_data/lv_db; KEY=/etc/luks-keys/db.key

[[ $EUID -eq 0 ]] || { echo "нужен root"; exit 1; }
mkdir -p $D && chmod 700 $D && : > $D/err
err() { echo "$*" >> $D/err; }

if [[ -z ${B3_FORCE:-} ]] && ! bash $VERIFY >/dev/null 2>&1; then
  echo "стенд не совпадает с эталоном — сначала verify-storage.sh без FAIL"; exit 1
fi

md_disks() { mdadm --detail $MD | awk -v s="$1" '$NF ~ /^\/dev\// && $0 ~ s {print $NF}'; }

# ---------- диски ----------
f16() {  # активный диск пропал с шины: массив degraded, ребилд на spare (если он есть и исправен)
  # диск выбирается так, чтобы его зеркальная пара (RaidDevice 0+1, 2+3) была цела — иначе RAID-10 умрёт
  local d; d=$(mdadm --detail $MD | awk '$NF ~ /^\/dev\// && $5 == "active" && $6 == "sync" {print $4, $NF}' \
               | awk '{rd[$1] = $2} END {for (r in rd) {p = (r % 2 == 0) ? r + 1 : r - 1; if (p in rd) print rd[r]}}' | shuf -n1)
  [[ -n $d ]] || { err "f16: нет диска с целой зеркальной парой"; return; }
  echo 1 > /sys/block/${d#/dev/}/device/delete 2>>$D/err
  sleep 3; [[ -e /sys/block/${d#/dev/} ]] && err "f16: $d не пропал"
}

# ---------- RAID ----------
f1() {  # spare вынули из массива, потом сбойнул активный диск: массив degraded без запаса
  local sp act; sp=$(md_disks 'spare' | head -1); act=$(md_disks 'active sync' | shuf -n1)
  [[ -n $sp && -n $act ]] || { err "f1: нет spare или активного диска"; return; }
  mdadm $MD --remove "$sp" >/dev/null 2>&1 || { err "f1: --remove $sp"; return; }
  sleep 2; mdadm $MD --fail "$act" >/dev/null 2>&1
  sleep 1; md_disks 'faulty' | grep -qx "$act" || err "f1: $act не помечен faulty"
}
f2() {  # spare сбойный, но так и висит в массиве
  local sp; sp=$(md_disks 'spare' | head -1)
  [[ -n $sp ]] || { err "f2: нет spare"; return; }
  mdadm $MD --fail "$sp" >/dev/null 2>&1
  sleep 1; md_disks 'faulty' | grep -qx "$sp" || err "f2: $sp не помечен faulty"
}
f17() {  # скорость ребилда задушена до 10 КБ/с: после пропажи диска (f16) ребилд на spare ползёт сутками
  sysctl -q -w dev.raid.speed_limit_min=1 dev.raid.speed_limit_max=10 2>>$D/err
  [[ $(sysctl -n dev.raid.speed_limit_max) == 10 ]] || err "f17: speed_limit_max не 10"
}
f3() {  # mdadm.conf «с другого сервера»: чужой ARRAY и AUTO -all, initramfs пересобран — после ребута массив не собирается
  local u; u=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n' | sed -E 's/(.{8})(.{8})(.{8})(.{8})/\1:\2:\3:\4/')
  sed -i -E "s/^(ARRAY .*UUID=)[0-9a-f:]+/\1$u/" /etc/mdadm/mdadm.conf
  grep -q '^AUTO' /etc/mdadm/mdadm.conf || sed -i 's/^HOMEHOST <system>$/&\nAUTO -all/' /etc/mdadm/mdadm.conf
  grep -q "^AUTO -all" /etc/mdadm/mdadm.conf && grep -q "UUID=$u" /etc/mdadm/mdadm.conf || err "f3: mdadm.conf не изменён"
  update-initramfs -u -k "$(uname -r)" >/dev/null 2>>$D/err.f3 || err "f3: update-initramfs: $(tail -1 $D/err.f3)"
  rm -f $D/err.f3
}
# ---------- LVM ----------
f4() {  # ручной снапшот «перед обновлением» забыли удалить: в VG < 500M, бэкап не создаёт свой снапшот
  local free; free=$(vgs --noheadings --units m --nosuffix -o vg_free vg_data | awk '{printf "%d", $1}')
  lvcreate -s -L $((free - 300))M -n lv_db_before_upgrade vg_data/lv_db >/dev/null 2>>$D/err
}
f18() {  # lv_logs выключен: /srv/scanner не смонтирован, сканер стоит
  docker stop bucket-scanner >/dev/null 2>&1
  umount /srv/scanner 2>>$D/err && lvchange -an vg_data/lv_logs 2>>$D/err
  [[ $(lvs --noheadings -o lv_active vg_data/lv_logs | tr -d ' ') == active ]] && err "f18: lv_logs активен"
}
# ---------- LUKS ----------
f5() {  # удалён слот с файлом-ключом — после ребута том ждёт пароль на консоли
  local s; [[ $(cryptsetup luksDump /backup/luks/lv_db-header.img 2>/dev/null | grep -cE '^ +[0-9]+: luks2') -eq 2 ]] \
    || { err "f5: нет исправного бэкапа заголовка — не трогаю"; return; }
  for s in 0 1 2 3 4 5 6 7; do
    cryptsetup open --test-passphrase --key-file $KEY --key-slot $s $LV 2>/dev/null && break; s=
  done
  [[ -n $s ]] || { err "f5: файл-ключ не открывает ни один слот"; return; }
  cryptsetup luksKillSlot -q $LV "$s" </dev/null >/dev/null 2>&1
  cryptsetup luksDump $LV | grep -qE "^ +$s: luks2" && err "f5: слот $s не удалён"
}
f6() {  # опечатка в пути к ключу в crypttab — после ребута том ждёт пароль на консоли
  sed -i 's#/etc/luks-keys/db\.key#/etc/luks-key/db.key#' /etc/crypttab
  grep -q '/etc/luks-key/db.key' /etc/crypttab || err "f6: crypttab не изменён"
}
f19() {  # в crypttab дописан readonly — после ребута том открыт только на чтение, база падает
  sed -i -E 's/^(db_crypt .* luks)$/\1,readonly/' /etc/crypttab
  grep -qE '^db_crypt .* luks,readonly$' /etc/crypttab || err "f19: crypttab не изменён"
}
f20() {  # db_crypt переоткрыт руками только на чтение: база падает с Read-only file system
  systemctl stop postgresql@16-main
  umount /var/lib/postgresql 2>>$D/err || return
  systemctl stop systemd-cryptsetup@db_crypt
  cryptsetup open --readonly --key-file $KEY $LV db_crypt 2>>$D/err || return
  mount /var/lib/postgresql 2>/dev/null
  systemctl start postgresql@16-main 2>/dev/null
  [[ $(blockdev --getro /dev/mapper/db_crypt 2>/dev/null) == 1 ]] || err "f20: db_crypt не только на чтение"
}
f21() {  # затёрт заголовок LUKS: systemd гасит базу и отмонтирует том; восстанавливается из /backup/luks
  [[ $(cryptsetup luksDump /backup/luks/lv_db-header.img 2>/dev/null | grep -cE '^ +[0-9]+: luks2') -eq 2 ]] \
    || { err "f21: нет исправного бэкапа заголовка — не трогаю"; return; }
  dd if=/dev/zero of=$LV bs=1M count=16 conv=fsync status=none 2>>$D/err
  sleep 3; cryptsetup isLuks $LV 2>/dev/null && err "f21: заголовок не затёрт"
}
# ---------- ФС и монтирование ----------
f7() {  # на /backup кончились inode: распаковали «тестовое восстановление» из мелких файлов
  python3 - <<'EOF' 2>>$D/err
import os, errno
base = '/backup/restore-test'
os.makedirs(base, exist_ok=True)
keep = int(os.environ.get('B3_KEEP_INODES', '0'))   # оставить inode для f8 в том же наборе
n = 0
try:
    while not (keep and n % 100 == 0 and os.statvfs(base).f_ffree <= keep):
        d = os.path.join(base, 'pg_wal.%04d' % (n // 1000))
        if n % 1000 == 0: os.mkdir(d)
        os.close(os.open(os.path.join(d, '%024X' % n), os.O_CREAT | os.O_WRONLY, 0o600))
        n += 1
except OSError as e:
    if e.errno != errno.ENOSPC: raise
EOF
}
f8() {  # зависший процесс держит удалённый файл на /backup: df 100% (и резерв root), du ничего не видит
  setsid -f bash -c "exec 3>/backup/db/.rsync-stream; head -c 8G /dev/zero >&3 2>/dev/null; rm -f /backup/db/.rsync-stream
                     exec -a 'rsync --server -logDtpre.iLsfxC . /backup/db/' sleep infinity" </dev/null >/dev/null 2>&1
  local i; for i in $(seq 60); do        # head пишет ~2 ГБ: держатель с (deleted) появится через несколько секунд
    find /proc/[0-9]*/fd -lname '/backup/db/.rsync-stream (deleted)' 2>/dev/null | grep -q . && return; sleep 1
  done
  err "f8: держатель не найден за 60 с"
}
f9() {  # в fstab для /backup убран nofail и сбит UUID — после ребута emergency mode
  local u; u=$(awk '$2 == "/backup" {print $1}' /etc/fstab)
  [[ $u == UUID=* ]] || { err "f9: нет строки /backup по UUID"; return; }
  local v=${u%?}$(printf '%x' $(( (0x${u: -1} + 7) % 16 )))      # последняя цифра UUID другая
  sed -i -E "\#^$u /backup # { s#^$u#$v#; s#,nofail##; }" /etc/fstab
  grep -qE "^$v /backup .*noexec 0 2$" /etc/fstab || err "f9: fstab не изменён"
}
f22() {  # /srv/scanner забит дампом памяти сканера: место 100%, лог не пишется
  local d=/srv/scanner/tmp f a i
  mkdir -p $d; f=$d/core.scanner.$((30000 + RANDOM % 30000)); : > $f
  for i in $(seq 40); do      # до нуля свободного для не-root; не влезло (метаданные) — половину
    a=$(df --output=avail -B1 /srv/scanner | tail -1); (( a > 0 )) || break
    fallocate -o "$(stat -c %s $f)" -l "$a" $f 2>/dev/null \
      || fallocate -o "$(stat -c %s $f)" -l $((a / 8192 * 4096 + 4096)) $f 2>/dev/null
  done
  touch -d '-7 hours' $f
  [[ $(df --output=avail /srv/scanner | tail -1 | tr -d ' ') -eq 0 ]] || err "f22: на /srv/scanner осталось место"
}
f23() {  # /srv/scanner перемонтирован только на чтение: сканер не может открыть лог
  docker stop bucket-scanner >/dev/null 2>&1
  mount -o remount,ro /srv/scanner 2>>$D/err
  docker start bucket-scanner >/dev/null 2>&1
  findmnt -n -o OPTIONS /srv/scanner | grep -q '^ro,' || err "f23: /srv/scanner не ro"
}
# ---------- сервисы ----------
f10() { chmod 755 /var/lib/postgresql/16/main 2>>$D/err; }                 # PG не стартует: invalid permissions
f11() {                                                                      # после ребута кластер PG не стартует, в логах пусто
  local f=/etc/postgresql/16/main/start.conf
  sed -i -E 's/^auto$/manual/' $f; grep -qx manual $f || err "f11: start.conf не изменён"
}
f12() {                                                                      # после рестарта nfs-server снова есть NFSv3
  sed -i -E 's/^(\s*vers3\s*=\s*)n/\1y/' /etc/nfs.conf
  [[ $(nfsconf --get nfsd vers3) == y ]] || err "f12: nfs.conf не изменён"
}
f24() {  # PostgreSQL переехал на порт 5433: приложение получает connection refused на 5432
  sed -i -E 's/^port = 5432\b/port = 5433/' /etc/postgresql/16/main/postgresql.conf
  systemctl restart postgresql@16-main 2>>$D/err
  pg_lsclusters -h | grep -qE '^16 +main +5433 +online' || err "f24: кластер не на 5433"
}
f25() {  # база упала: postmaster убит, кластер лежит
  local p; p=$(head -1 /var/lib/postgresql/16/main/postmaster.pid 2>/dev/null)
  [[ -n $p ]] && kill -KILL "$p" 2>>$D/err; sleep 3
  pg_lsclusters -h | grep -qE '^16 +main .* down ' || err "f25: кластер не упал"
}
f26() {  # nfs-server выключен из автозапуска — после ребута NFS не поднимается
  systemctl disable -q nfs-server 2>>$D/err
  [[ $(systemctl is-enabled nfs-server) == disabled ]] || err "f26: nfs-server не выключен"
}
# ---------- права ----------
f13() { setfacl -m m::--- /srv/scanner/reports 2>>$D/err; }                 # маска ACL режет auditor и группу
f27() { chgrp root /srv/scanner/reports 2>>$D/err; }                        # у каталога отчётов сменили группу
f28() { chown root:root /srv/scanner/reports/scanner.log 2>>$D/err; }       # у лога сменили владельца и группу
f29() { chmod u-w /srv/scanner/reports/scanner.log 2>>$D/err; }             # у владельца лога сняли запись
rr()  { docker restart bucket-scanner >/dev/null 2>&1; }                     # перезапуск сканера: права проверяются при open()
# ---------- бэкап ----------
f14() { mv /etc/sudoers.d/backup /etc/sudoers.d/backup.conf 2>>$D/err; }    # sudo игнорирует файлы с точкой
f15() {                                                                      # cron игнорирует файл без \n в конце
  [[ -z $(tail -c1 /etc/cron.d/db-backup) ]] && truncate -s -1 /etc/cron.d/db-backup || err "f15: нет \\n в конце"
}
f30() {  # cron остановлен и выключен из автозапуска
  systemctl disable -q --now cron 2>>$D/err
  systemctl is-active -q cron && err "f30: cron работает"
}
f31() {  # в расписании бэкапа 31 февраля — задание не запустится никогда
  sed -i 's|^17 3 \* \* \* backup|17 3 31 2 * backup|' /etc/cron.d/db-backup
  grep -q '^17 3 31 2 \* backup' /etc/cron.d/db-backup || err "f31: расписание не изменено"
}
f32() { chmod -x /usr/local/bin/db-backup.sh 2>>$D/err; }                  # у скрипта бэкапа снят x

# часть 2: --boot. Первый вызов — случайная из f3/f9, root остаётся заблокированным (2а).
# Второй — другая, и root получает случайный пароль, который нигде не сохраняется (2б).
if [[ ${1:-} == --boot ]]; then
  if [[ ! -s $D/boot1 ]]; then
    f=$(printf '%s\n' f3 f9 | shuf -n1); echo "$f" > $D/boot1
  else
    f=$( [[ $(cat $D/boot1) == f3 ]] && echo f9 || echo f3 ); rm -f $D/boot1
    pw=$(head -c 18 /dev/urandom | base64 | tr -d '/+='); echo "root:$pw" | chpasswd 2>>$D/err; unset pw
    [[ $(passwd -S root | awk '{print $2}') == P ]] || err "boot: пароль root не задан"
  fi
  "$f"
  if [[ -s $D/err ]]; then echo "ОШИБКИ ВНЕСЕНИЯ:"; cat $D/err; exit 1; fi
  echo "поломка загрузки внесена — перезагрузи сервер"; exit 0
fi

# часть 1: f3 и f9 (валят загрузку) сюда не входят.
# Слои снизу вверх: диски, RAID, LVM, LUKS, ФС, сервисы, права, бэкап.
# Повтор в списке = вес: «живые» поломки сервисов и LUKS реже проходят условие «две после ребута»,
# без веса база-упала и не-тот-порт выпадали бы в 9% прогонов.
LAYERS=("f16" "f1 f2 f17" "f4 f18" "f5 f6 f19 f20 f20 f21 f21 f21" "f7 f8 f22 f23 f23"
        "f10 f11 f12 f24 f24 f24 f25 f25 f25 f26" "f13 f27 f28 f29" "f14 f15 f30 f31 f32")
DOUBLE="2 3 4 5 6 7"          # на дисках одна поломка; две в RAID не уживаются — обеим нужен spare
REBOOT=" f5 f6 f10 f11 f12 f19 f26 "
# несовместимые: одна поглощает другую или вместе ломают стенд без возврата
EXCL=" f5+f6 f5+f21 f20+f21 f4+f21 f18+f23 f20+f25 f21+f25 "
# одна под другой: вторую не видно, пока не починена первая
STACK=" f16+f17 f18+f22 f13+f18 f18+f27 f18+f28 f18+f29 f19+f20 f19+f21 f6+f21 f6+f20 f5+f20 f7+f8 f22+f23 \
f24+f25 f10+f25 f10+f20 f10+f21 f20+f24 f21+f24 f12+f26 f13+f27 f28+f29 f15+f31 f15+f30 f30+f31 f14+f32 "
# порядок внесения: сначала то, что лежит на томах, потом сами тома, в конце диски
ORDER="f13 f27 f28 f29 rr f22 f23 f7 f8 f24 f25 f10 f11 f12 f26 f14 f31 f15 f30 f32 f20 f19 f6 f5 f21 f4 f18 f17 f1 f2 f16 f3 f9"

has()  { [[ " ${SEL[*]} " == *" $1 "* ]]; }

if [[ -n ${B3_ONLY:-} ]]; then
  SEL=($B3_ONLY)
else
  while :; do
    SEL=()
    for l in 0 1 2 3 4 5 6 7; do SEL+=("$(printf '%s\n' ${LAYERS[$l]} | shuf -n1)"); done
    for l in $(printf '%s\n' $DOUBLE | shuf -n "$(shuf -i 1-2 -n1)"); do
      SEL+=("$(printf '%s\n' ${LAYERS[$l]} | grep -vxF -f <(printf '%s\n' "${SEL[@]}") | shuf -n1)")
    done
    ok=1; nr=0; ns=0
    for a in "${SEL[@]}"; do
      [[ $REBOOT == *" $a "* ]] && nr=$((nr + 1))
      for b in "${SEL[@]}"; do
        (( ${a#f} < ${b#f} )) || continue; p=$a+$b
        [[ $EXCL == *" $p "* ]] && ok=0; [[ $STACK == *" $p "* ]] && ns=$((ns + 1))
      done
    done
    (( ok && nr >= 2 && ns >= 1 )) && break
  done
fi

has f8 && export B3_KEEP_INODES=64
for f in $ORDER; do
  if [[ $f == rr ]]; then { has f27 || has f28 || has f29; } && rr; continue; fi
  has "$f" && "$f"
done
printf '%s\n' "${SEL[@]}" | sort -V | base64 > $D/sel
if [[ -s $D/err ]]; then echo "ОШИБКИ ВНЕСЕНИЯ:"; cat $D/err; exit 1; fi
echo "внесено поломок: ${#SEL[@]}"
