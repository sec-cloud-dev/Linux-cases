# Linux-cases

Решения Linux-кейсов: администрирование, отказоустойчивость, безопасность и автоматизация.

## Метод

Каждый блок состоит из двух частей.

**Сборка** — стенд поднимается руками, по ТЗ, которое написано до начала работы. Результат — запись одним дублем.

**Трабалшутинг** — на собранном стенде скрипт вносит поломки, выбирая их случайно. Набор до запуска неизвестен. Стенд считается восстановленным не когда «пингуется», а когда текущее состояние полностью совпадает с заранее снятым эталоном: таблицы маршрутизации, правила фаервола, конфиги, маршруты внутри неймспейсов и контейнеров.

## Блоки

| Блок | О чём | Сборка | Трабалшутинг |
|---|---|---|---|
| **01 — Защищённая среда** | Пользователи, изоляция home, `/srv/project`, ACL, `rbash`, Docker `FROM scratch`, sudo | [ТЗ](01-secured-environment/TZ.md) · [видео ~6:38](01-secured-environment/block-1.mp4) | — |
| **02 — Сетевая архитектура** | netns `dev-router`, bonding/bridge, PBR, nftables, WireGuard | [ТЗ](02-network-architecture/TZ.md) · [видео ~19 мин](02-network-architecture/block-2.mp4) | [разбор](02-network-architecture/troubleshooting/README.md) · [видео 13:19](https://github.com/sec-cloud-dev/Linux-cases/releases/tag/block2-troubleshooting) |
| **03 — Хранилище** | RAID-10 + hot spare, LVM, LUKS2, XFS, PostgreSQL, бэкап со снапшотов LVM, NFSv4 | [ТЗ](03-storage/TZ.md) · [разбор](03-storage/README.md) · [видео 1:32:23](03-storage/block-3.mp4) | — |

Гифки лежат рядом с README каждого блока — на GitHub открываются прямо в файле. Условия кейса — в `TZ.md` внутри папки блока.

## Структура

```
Linux-cases/
├── README.md
├── 01-secured-environment/
│   ├── TZ.md
│   ├── README.md
│   ├── block-1.mp4
│   └── gifs/
├── 02-network-architecture/
│   ├── TZ.md
│   ├── README.md
│   ├── block-2.mp4
│   ├── gifs/
│   └── troubleshooting/
│       ├── TZ.md          условия: вслепую, один дубль, критерий приёмки
│       ├── README.md      разбор прогона
│       ├── faults.md      каждая поломка: симптом, локализация, причина, фикс
│       ├── verify.sh      30 проверок: функциональные + дифф против эталона
│       ├── etalon/        снимки эталонного состояния
│       ├── break/         скрипт внесения поломок
│       └── gifs/
└── 03-storage/
    ├── TZ.md
    ├── README.md
    ├── block-3.mp4
    ├── scripts/           db-backup.sh, verify-storage.sh, md-*.sh, disk2.sh (хост)
    ├── systemd/           md-run-degraded.service
    ├── docker/            Dockerfile scanner:v2
    ├── configs/           fstab, crypttab, mdadm.conf, exports, nftables.conf, cron, sudoers
    ├── etalon/            снимки эталонного состояния
    └── gifs/
```
