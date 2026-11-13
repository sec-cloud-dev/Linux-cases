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
# md: заголовок без счётчика событий; State active = clean — после каждой записи массив
# на 0,2 с становится active, это не изменение состояния. Вместо таблицы слотов — набор
# дисков: после замены диска или ребилда диски меняются ролями (бывший spare становится
# активным), и это не расхождение — число активных и spare сверяется по заголовку.
snap_md()     { mdadm --detail /dev/md/data | sed '/^ *Number /,$d' | grep -vE 'Events|Update Time' \
                | sed -E 's/^( *State : )active/\1clean/' | norm
                echo "members:"; mdadm --detail /dev/md/data | awk 'NR > 1 && $NF ~ /^\/dev\// {print $NF}' | norm | sort; }
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
snap_conf()   { echo "# mdadm.conf"; grep -vE '^\s*(#|$)' /etc/mdadm/mdadm.conf
                echo "# nfs.conf"; nfsconf --dump
                echo "# cron.d, sudoers.d"; find /etc/cron.d /etc/sudoers.d -maxdepth 1 -type f -printf '%p %u:%g %m\n' | sort
                cat -A /etc/cron.d/db-backup; echo
                echo "# postgresql start.conf"; grep -vE '^\s*(#|$)' /etc/postgresql/16/main/start.conf
                echo "# docker"; docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}} {{.Config.User}}' bucket-scanner
                echo "# права"; stat -c '%n %U:%G %a' /srv/scanner /srv/scanner/reports /srv/scanner/reports/scanner.log \
                  /usr/local/bin/db-backup.sh; }
ITEMS="lsblk md lvm luks mounts fstab acl attr sudo nfs nft conf"

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
c_no_snap()     { [[ $(vgs --noheadings -o snap_count vg_data | tr -d ' ') -eq 0 ]]; }
c_luks_open()   { cryptsetup status db_crypt | grep -q 'LUKS2'; }
c_luks_slots()  { [[ $(cryptsetup luksDump /dev/vg_data/lv_db | grep -cE '^ +[0-9]+: luks2') -eq 2 ]]; }
c_luks_hdr()    { [[ -f /backup/luks/lv_db-header.img && $(stat -c %a /backup/luks) == 700 ]] \
                  && [[ $(cryptsetup luksDump /backup/luks/lv_db-header.img | grep -cE '^ +[0-9]+: luks2') -eq 2 ]]; }
c_crypt_key()   { local u k; read -r u k < <(awk '$1 == "db_crypt" {print $2, $3}' /etc/crypttab)
                  [[ $u == UUID=* && -b /dev/disk/by-uuid/${u#UUID=} && -f $k ]] \
                  && cryptsetup open --test-passphrase --key-file "$k" "/dev/disk/by-uuid/${u#UUID=}"; }
c_key_immut()   { lsattr /etc/luks-keys/db.key | awk '{print $1}' | grep -q i; }
c_mnt_db()      { findmnt -n -o SOURCE /var/lib/postgresql | grep -q db_crypt; }
c_mnt_logs()    { findmnt -n -o SOURCE /srv/scanner | grep -q lv_logs; }
c_mnt_backup()  { mountpoint -q /backup; }
c_mnt_tmp()     { findmnt -n -o FSTYPE,OPTIONS /tmp | grep -qE '^tmpfs .*size=524288k'; }
c_noexec()      { findmnt -n -o OPTIONS /srv/scanner | grep -q noexec && findmnt -n -o OPTIONS /backup | grep -q noexec; }
c_fstab_uuid()  { ! grep -vE '^\s*(#|$)' /etc/fstab | awk '$2 ~ /^\/(var\/lib\/postgresql|srv\/scanner|backup)$/ {print $1}' | grep -qv '^UUID='; }
c_pg_online()   { pg_lsclusters -h | grep -qE '^16 +main .*online'; }
c_pg_data()     { local n; n=$(sudo -u postgres psql -Atd scanner -c 'select count(*) from scan_results') && (( n >= 100 )); }
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
# --- то, что проявляется только после перезагрузки или копится незаметно ---
c_md_nofail()   { mdadm --detail /dev/md/data | grep -qE 'Failed Devices : 0$'; }
c_md_conf()     { local u; u=$(mdadm --detail /dev/md/data | awk '$1 == "UUID" {print $3}')
                  [[ -n $u ]] && grep -E '^ARRAY ' /etc/mdadm/mdadm.conf | grep -q "UUID=$u"; }
c_md_initrd()   { local d f r=1; d=$(mktemp -d -p /var/tmp)
                  unmkinitramfs "/boot/initrd.img-$(uname -r)" "$d" >/dev/null 2>&1
                  f=$(find "$d" -path '*/etc/mdadm/mdadm.conf' -print -quit)
                  [[ -n $f ]] && diff -q <(grep -vE '^\s*(#|$)' "$f") <(grep -vE '^\s*(#|$)' /etc/mdadm/mdadm.conf) && r=0
                  rm -rf "$d"; return $r; }
c_fstab_ok()    { findmnt --verify --tab-file /etc/fstab; }
c_df()          { df --output=pcent,ipcent /var/lib/postgresql /srv/scanner /backup | tail -n +2 | tr -d '%' \
                  | awk '$1 >= 90 || $2 >= 90 {bad = 1} END {exit bad}'; }
c_no_deleted()  { ! find /proc/[0-9]*/fd \( -lname '/backup/* (deleted)' -o -lname '/srv/scanner/* (deleted)' \) \
                  -print 2>/dev/null | grep -q .; }
c_pg_auto()     { [[ $(grep -vE '^\s*(#|$)' /etc/postgresql/16/main/start.conf) == auto ]]; }
c_nfs_conf()    { [[ $(nfsconf --get nfsd vers3) == n ]]; }
c_root_locked() { [[ $(passwd -S root | awk '{print $2}') == L ]]; }
c_md_speed()    { [[ $(sysctl -n dev.raid.speed_limit_min) == 1000 && $(sysctl -n dev.raid.speed_limit_max) == 200000 ]]; }
c_pg_port()     { pg_lsclusters -h | grep -qE '^16 +main +5432 '; }
c_nfs_enabled() { systemctl is-enabled -q nfs-server; }
c_scan_log()    { local f=/srv/scanner/reports/scanner.log; [[ -f $f ]] && (( $(date +%s) - $(stat -c %Y $f) < 60 )); }
c_cron_svc()    { systemctl is-enabled -q cron && systemctl is-active -q cron; }
c_bk_script()   { [[ $(stat -c '%U %a' /usr/local/bin/db-backup.sh) == 'root 755' ]]; }
c_cron_file()   { local f=/etc/cron.d/db-backup; [[ $(stat -c '%U %a' $f) == 'root 644' && -z $(tail -c1 $f) ]]; }

echo "== RAID / LVM / LUKS =="
check "/dev/md/data указывает на массив"        c_md_link
check "массив полный, не degraded"              c_md_full
check "в массиве есть spare"                    c_md_spare
check "md-alert подключён, mdmonitor работает"  c_md_alert
check "служба md-run-degraded включена"         c_md_degr_svc
check "в массиве нет сбойных дисков"           c_md_nofail
check "скорость ребилда по умолчанию"           c_md_speed
check "ARRAY в mdadm.conf — этот массив"       c_md_conf
check "mdadm.conf в initramfs актуален"        c_md_initrd
check "в VG свободно не меньше 20%"             c_vg_free
check "в VG нет снапшотов (забытых)"           c_no_snap
check "db_crypt открыт (LUKS2)"                 c_luks_open
check "у LUKS ровно 2 слота"                    c_luks_slots
check "бэкап заголовка LUKS на /backup, 700"    c_luks_hdr
check "crypttab: ключ на месте и открывает"    c_crypt_key
check "файл-ключ неизменяемый (+i)"             c_key_immut
echo "== ФС и монтирование =="
check "база на db_crypt"                        c_mnt_db
check "логи на lv_logs"                         c_mnt_logs
check "/backup смонтирован"                     c_mnt_backup
check "/tmp — tmpfs 512M"                       c_mnt_tmp
check "noexec на логах и /backup"               c_noexec
check "fstab по UUID"                           c_fstab_uuid
check "fstab: findmnt --verify без ошибок"     c_fstab_ok
check "место и inode на томах < 90%"           c_df
check "нет удалённых, но открытых файлов"      c_no_deleted
echo "== База =="
check "кластер 16 main online"                  c_pg_online
check "данные в scan_results"                   c_pg_data
check "каталог данных postgres 700"             c_pg_perms
check "на томе базы только postgres"            c_pg_only
check "кластер стартует при загрузке (auto)"   c_pg_auto
check "кластер на порту 5432"                   c_pg_port
echo "== Права =="
check "reports: группа scanner, 2770"           c_rep_sgid
check "контейнер работает от 10001:1008"        c_container
check "отчёт от scanner-svc:scanner"            c_rep_owner
check "сканер пишет лог (< 60 с назад)"        c_scan_log
check "auditor читает отчёты"                   c_aud_read
check "auditor не пишет в отчёты"               c_aud_nowrite
check "auditor не в группе scanner"             c_aud_nogroup
check "backup: в sudo только скрипт"            c_sudo_backup
check "root заблокирован (вход только sudo)"   c_root_locked
echo "== Бэкап =="
check "cron работает и в автозапуске"          c_cron_svc
check "cron на бэкап есть"                      c_bk_cron
check "cron-файл: root 644, перевод строки"    c_cron_file
check "скрипт бэкапа root 755"                  c_bk_script
check "бэкапов от 1 до 7"                       c_bk_count
echo "== NFS =="
check "экспорт /backup ro, root_squash"         c_nfs
check "nfs-server в автозапуске"                c_nfs_enabled
check "NFSv3 выключен"                          c_nfs_v3off
check "NFSv3 выключен в nfs.conf"              c_nfs_conf
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
