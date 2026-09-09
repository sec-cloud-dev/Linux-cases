# Linux-cases

Решения двух Linux-кейсов: администрирование, отказоустойчивость, безопасность и автоматизация.

Гифки лежат рядом с README каждого блока — на GitHub они открываются прямо в файле.

| Блок | О чём | Видео |
|------|--------|--------|
| [01 — Защищённая среда](./01-secured-environment/) | Пользователи, изоляция home, `/srv/project`, ACL, rbash, Docker `FROM scratch`, sudo | [block-1.mp4](./01-secured-environment/block-1.mp4) (~6:38) |
| [02 — Сетевая архитектура](./02-network-architecture/) | netns `dev-router`, bonding/bridge, PBR, nftables, WireGuard, DNS/IPv6 | [block-2.mp4](./02-network-architecture/block-2.mp4) (~19 мин) |

```
Linux-cases/
├── README.md
├── 01-secured-environment/
│   ├── README.md      ← гифки вставлены в разделы
│   ├── block-1.mp4
│   └── gifs/
└── 02-network-architecture/
    ├── README.md
    ├── block-2.mp4
    └── gifs/
```
