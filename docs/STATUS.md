# Статус cream-extensions

**Фаза:** перевод каталога на cream/v1 по плану
[2026-10-19-cream-v1-migration](plans/2026-10-19-cream-v1-migration.md) — задачи 1–28 закрыты,
Task 29 (финальная интеграция) — PR выпуска 5.0.0 открыт. Набор расширений в `main` — 4.0.0.

## Сделано
- Все 44 расширения — cream/v1 (`/opt/cream/ext`, `/etc/cream`, `/var/lib/cream/ext`);
  общий код — библиотеки `cloud-user`, `l4t` и `apt-guard` (`kind: library`).
- Переходное убрано (Task 28): `lib/`, валидатор прежнего формата, `convert-v1.py`, тест библиотеки
  настроек, `extensions/openwrt/` (файлы OpenWrt bisquite берёт по тегу `v3.3.0`, рулинг Р3).
- `cream validate --catalog .` — по корню как он есть; снимок — `roots` из `cream-catalog.yaml`;
  гейт имён `tools/check-names.sh` — по всему репозиторию, кроме истории (CHANGELOG, docs/research,
  docs/plans), двоичные файлы пропускает.

## Дальше
0. PR `fix:` по финальному ревью 5.0.0: `remove` снимает пакеты только через `apt-guard`
   (новая зависимость 21 расширения — рецептам bisquite нужен слой `EXTENSION apt-guard`),
   `can-usb` сверяет архив до распаковки, группы `pixelflux-tegra`, имя в `cloud-user`/`docker`.
1. Task 29: PR каталога 5.0.0 (`feat!:`, `Release-As: 5.0.0`) — слияние и выпуск решает владелец;
   автоподъём пина каталога в bisquite не включать до плана bisquite.
2. Бэклог после 5.0.0 — раздел «Бэклог после 5.0.0» плана
   [2026-10-19-cream-v1-migration](plans/2026-10-19-cream-v1-migration.md).
3. Разгрести предупреждения shellcheck вне расширений (планка `make lint` — error).

## Ждут живой проверки (P: платы и bisquite)
V и H пройдены у всех; живой проверки на железе или в сборке ещё не было.
- Сборка образа через bisquite (после плана bisquite; владелец): `cloud-growroot`,
  `nocloud-cidata`, `l4t-kernel-kvm`.
- Плата Jetson вручную по README (владелец): `jetson-stats`, `cuda-toolkit`, `tensorrt`,
  `l4t-gstreamer`, `l4t-opencv`, `l4t-pytorch`, `l4t-tensorflow`, `l4t-board-fdt`,
  `l4t-boot-verify`, `pixelflux-tegra`, `pixelflux-v4l2m2m`.
- Плата Jetson с камерами Sensing GMSL2 (владелец): `sensing-gmsl2-camera`, `can-usb`.
- ВМ с GPU NVIDIA (владелец): `nvidia`, `nvidia-container-toolkit`.
- ПК-станция с платой в режиме прошивки (владелец): `nvidia-jetpack`.

## Сломано
- `cream validate` предупреждает `validate.unit_lock` у `teleport` (3 юнита на пине cream 1.1.1) —
  предупреждение, не ошибка; разобрать после 5.0.0 (в бэклоге плана).
