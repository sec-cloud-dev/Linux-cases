# Кейс блока 1: Защищённая среда для команды разработки + деплой приложения

**A — Пользователи:** 3 разработчика в группе `devteam` + сервисный пользователь `system_dev` (`nologin`, пароль заблокирован)

**B — Домашние директории:** изоляция друг от друга, root видит всё

**C — `/srv/project`:** SGID (наследование группы), sticky bit (только автор удаляет свой файл), `chattr +i` на `deploy_config.yml`

**D — ACL:** `auditor` (не в `devteam`) — только `r-x` на `/srv/project`, без записи

**E — Restricted shell:** один разработчик получает `rbash` — без `cd`, без абсолютных путей, без смены `PATH`, без `>` / `>>`

**F — Приложение:** простая C-программа (`bucket-scanner`, работает постоянно), multi-stage Docker build со статической линковкой, `FROM scratch`, контейнер с явным именем

**G — SUID-аудит:** найти и убрать подложенный SUID-бит через `find -perm /4000`

**H — Sudo:** `system_dev` — только `docker restart bucket-scanner`, NOPASSWD, без wildcard
