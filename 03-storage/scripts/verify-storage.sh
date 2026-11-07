#!/bin/bash
# verify-storage.sh — проверка стенда блока 3
#   без аргументов: функциональные проверки + дифф с эталоном
#   --etalon:       снять эталон

ET=/root/etalon/storage
PASS=0; FAIL=0
ok()    { echo "PASS $1"; PASS=$((PASS+1)); }
bad()   { echo "FAIL $1"; FAIL=$((FAIL+1)); }
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }

# ---------- имена дисков без букв ----------
# Буквы sdX и номер mdNNN зависят от порядка, в котором ядро нашло диски: после
# загрузки без диска и его возврата они сдвигаются. В эталон идут серийники дисков
# и имя массива md/data — они от порядка не зависят.
disk_map() { lsblk -dnr -o NAME,TYPE,SERIAL | awk '$2 == "disk" && $3 != "" {print $1, $3}'; }
norm() {
  local e=() n s md
  while read -r n s; do
    e+=(-e "s#(/dev/)?\\b$n([0-9]+)\\b#$s-part\\2#g" -e "s#(/dev/)?\\b$n\\b#$s#g")
  done < <(disk_map)
  md=$(basename "$(readlink -f /dev/md/data)")
  e+=(-e "s#(/dev/)?\\b$md\\b#md/data#g")
  sed -E "${e[@]}"
}

# ---------- снимки для эталона ----------
snap_lsblk()  { local n s                       # каждый диск отдельно, по порядку серийников
                disk_map | sort -k2 | while read -r n s; do
                  paste <(lsblk -n -i -o NAME "/dev/$n") \
                        <(lsblk -n -r -o TYPE,FSTYPE,UUID,MOUNTPOINTS "/dev/$n" | tr ' ' '\t')
                done | norm | awk -F'\t' '{sub(/ +$/, "", $1)
                  printf "%-30s %-7s %-18s %-38s %s\n", $1, $2, $3, $4, $5}' | sed 's/ *$//'; }
# md: без счётчика событий и Major/Minor; State active = clean — после каждой записи
# массив на 0,2 с становится active, это не изменение состояния
snap_md()     { mdadm --detail /dev/md/data | grep -vE 'Events|Update Time' \
                | sed -E -e 's/^( *State : )active/\1clean/' \
                         -e 's/^( *Number) +Major +Minor +/\1   /' \
                         -e 's/^( +[0-9]+) +[0-9]+ +[0-9]+ +/\1   /' | norm; }
snap_lvm()    { { pvs -o pv_name,vg_name,pv_size --units m
                  vgs -o vg_name,pv_count,lv_count,snap_count,vg_size,vg_free --units m
                  lvs -o lv_name,vg_name,lv_size,lv_attr --units m; } | norm; }
snap_luks()   { cryptsetup luksDump /dev/vg_data/lv_db | grep -E '^ +[0-9]+: luks2'; }
snap_mounts() { for t in /var/lib/postgresql /srv/scanner /backup /tmp; do
                  findmnt -n -o TARGET,SOURCE,FSTYPE,OPTIONS "$t"; done | norm; }
snap_fstab()  { grep -vE '^\s*(#|$)' /etc/fstab; echo ---; grep -vE '^\s*(#|$)' /etc/crypttab; }
snap_acl()    { getfacl -p /srv/scanner/reports; }
snap_attr()   { lsattr /etc/luks-keys/db.key; }
snap_sudo()   { sudo -l -U backup | sed -n '/may run/,$p'; }
snap_nfs()    { exportfs -v; }
snap_nft()    { nft -s list ruleset; }
ITEMS="lsblk md lvm luks mounts fstab acl attr sudo nfs nft"

if [[ ${1:-} == --etalon ]]; then
  mkdir -p "$ET"
  for i in $ITEMS; do "snap_$i" > "$ET/$i.txt" 2>&1; done
  echo "эталон сохранён в $ET"; exit 0
fi

# ---------- функциональные проверки ----------
c_md_link()     { [[ $(readlink -f /dev/md/data) == /dev/md* ]]; }
c_md_full()     { grep -q '\[UUUU\]' /proc/mdstat && ! mdadm --detail /dev/md/data | grep -q degraded; }
c_md_spare()    { mdadm --detail /dev/md/data | grep -qE 'Spare Devices : [1-9]'; }
c_md_alert()    { grep -q '^PROGRAM /usr/local/bin/md-alert.sh' /etc/mdadm/mdadm.conf && systemctl is-active -q mdmonitor; }
c_md_degr_svc() { systemctl is-enabled -q md-run-degraded.service; }
c_vg_free()     { vgs --noheadings --units b --nosuffix -o vg_size,vg_free vg_data | awk '{exit !($2/$1 >= 0.2)}'; }
c_no_snap()     { ! lvs vg_data/lv_db_snap; }
c_luks_open()   { cryptsetup status db_crypt | grep -q 'LUKS2'; }
c_luks_slots()  { [[ $(cryptsetup luksDump /dev/vg_data/lv_db | grep -cE '^ +[0-9]+: luks2') -eq 2 ]]; }
c_luks_hdr()    { [[ -f /backup/luks/lv_db-header.img && $(stat -c %a /backup/luks) == 700 ]]; }
c_key_immut()   { lsattr /etc/luks-keys/db.key | awk '{print $1}' | grep -q i; }
c_mnt_db()      { findmnt -n -o SOURCE /var/lib/postgresql | grep -q db_crypt; }
c_mnt_logs()    { findmnt -n -o SOURCE /srv/scanner | grep -q lv_logs; }
c_mnt_backup()  { mountpoint -q /backup; }
c_mnt_tmp()     { findmnt -n -o FSTYPE,OPTIONS /tmp | grep -qE '^tmpfs .*size=524288k'; }
c_noexec()      { findmnt -n -o OPTIONS /srv/scanner | grep -q noexec && findmnt -n -o OPTIONS /backup | grep -q noexec; }
c_fstab_uuid()  { ! grep -vE '^\s*(#|$)' /etc/fstab | awk '$2 ~ /^\/(var\/lib\/postgresql|srv\/scanner|backup)$/ {print $1}' | grep -qv '^UUID='; }
c_pg_online()   { pg_lsclusters -h | grep -qE '^16 +main .*online'; }
c_pg_data()     { sudo -u postgres psql -Atd scanner -c 'select count(*) from scan_results' | awk '{exit !($1 >= 100)}'; }
c_pg_perms()    { [[ $(stat -c '%U %a' /var/lib/postgresql/16/main) == 'postgres 700' ]]; }
c_pg_only()     { [[ -z $(find /var/lib/postgresql ! -user postgres -print -quit) ]]; }
c_rep_sgid()    { [[ $(stat -c '%G %a' /srv/scanner/reports) == 'scanner 2770' ]]; }
c_container()   { [[ $(docker inspect -f '{{.State.Running}} {{.Config.User}}' bucket-scanner) == 'true 10001:1008' ]]; }
c_rep_owner()   { [[ $(stat -c '%U %G' /srv/scanner/reports/scanner.log) == 'scanner-svc scanner' ]]; }
c_aud_read()    { sudo -u auditor head -c1 /srv/scanner/reports/scanner.log; }
c_aud_nowrite() { ! sudo -u auditor touch /srv/scanner/reports/.auditor-test; }
c_aud_nogroup() { ! id -nG auditor | grep -qw scanner; }
c_sudo_backup() { [[ $(sudo -l -U backup | sed -n '/may run/,$p' | tail -n +2 | grep -c .) -eq 1 ]] \
                  && sudo -l -U backup | grep -q 'db-backup.sh ""'; }
c_bk_cron()     { grep -q 'backup sudo -n /usr/local/bin/db-backup.sh' /etc/cron.d/db-backup; }
c_bk_count()    { local n; n=$(ls -1d /backup/db/20* 2>/dev/null | wc -l); [[ $n -ge 1 && $n -le 7 ]]; }
c_nfs()         { systemctl is-active -q nfs-server && exportfs -v | grep '^/backup' | grep '10.0.0.0/24' | grep ',ro,' | grep -qE '[(,]root_squash'; }
c_nfs_v3off()   { grep -q -- '-3' /proc/fs/nfsd/versions; }
c_nft_live()    { nft -s list chain inet filter input | grep -q 'policy drop' \
                  && nft -s list chain inet filter input | grep -q 'iifname "br-office" ip saddr 10.0.0.0/24 tcp dport 2049'; }
c_nft_file()    { grep -q 'dport 2049' /etc/nftables.conf; }

echo "== RAID / LVM / LUKS =="
check "/dev/md/data указывает на массив"        c_md_link
check "массив полный, не degraded"              c_md_full
check "в массиве есть spare"                    c_md_spare
check "md-alert подключён, mdmonitor работает"  c_md_alert
check "служба md-run-degraded включена"         c_md_degr_svc
check "в VG свободно не меньше 20%"             c_vg_free
check "нет забытого снапшота"                   c_no_snap
check "db_crypt открыт (LUKS2)"                 c_luks_open
check "у LUKS ровно 2 слота"                    c_luks_slots
check "бэкап заголовка LUKS на /backup, 700"    c_luks_hdr
check "файл-ключ неизменяемый (+i)"             c_key_immut
echo "== ФС и монтирование =="
check "база на db_crypt"                        c_mnt_db
check "логи на lv_logs"                         c_mnt_logs
check "/backup смонтирован"                     c_mnt_backup
check "/tmp — tmpfs 512M"                       c_mnt_tmp
check "noexec на логах и /backup"               c_noexec
check "fstab по UUID"                           c_fstab_uuid
echo "== База =="
check "кластер 16 main online"                  c_pg_online
check "данные в scan_results"                   c_pg_data
check "каталог данных postgres 700"             c_pg_perms
check "на томе базы только postgres"            c_pg_only
echo "== Права =="
check "reports: группа scanner, 2770"           c_rep_sgid
check "контейнер работает от 10001:1008"        c_container
check "отчёт от scanner-svc:scanner"            c_rep_owner
check "auditor читает отчёты"                   c_aud_read
check "auditor не пишет в отчёты"               c_aud_nowrite
check "auditor не в группе scanner"             c_aud_nogroup
check "backup: в sudo только скрипт"            c_sudo_backup
echo "== Бэкап =="
check "cron на бэкап есть"                      c_bk_cron
check "бэкапов от 1 до 7"                       c_bk_count
echo "== NFS =="
check "экспорт /backup ro, root_squash"         c_nfs
check "NFSv3 выключен"                          c_nfs_v3off
check "nft: drop + 2049 с br-office (живой)"    c_nft_live
check "nft: 2049 в nftables.conf"               c_nft_file

echo "== Дифф с эталоном =="
if [[ ! -d $ET ]]; then
  bad "эталон не найден ($ET) — снять: $0 --etalon"
else
  for i in $ITEMS; do
    if d=$(diff -u "$ET/$i.txt" <("snap_$i" 2>&1)); then ok "эталон: $i"
    else bad "эталон: $i"; echo "$d" | tail -n +3 | grep -E '^[-+]' | sed 's/^/      /' | head -10; fi
  done
fi

echo "== Итого: PASS=$PASS FAIL=$FAIL =="
[[ $FAIL -eq 0 ]]
