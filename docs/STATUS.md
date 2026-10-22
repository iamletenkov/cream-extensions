# Статус cream-extensions

**Фаза:** каталог под cream 1.3.0 и bisquite 3 по плану cream
`docs/plans/2026-10-21-bisquite-bundled-cream.md` (репозиторий cream): Task 28 — корень
`extensions/openwrt` (`amneziawg`, `podkop`, `luci-apps`), следующий минор каталога.

## Сделано
- 49 расширений (из них 3 библиотеки) — cream/v1, из них 3 семейства `openwrt` (`make test-openwrt`
  на корневой ФС openwrt-builder v0.3.0, CI-job `test-openwrt`); 12 с `every_boot` и `cream: ">=1.2.0"`;
  `cream check` по каталогу и правило `every-boot` ошибкой — в CI.
- Документация по задачам: README с таблицей расширений, [первые шаги](getting-started.md),
  `guides/`, `reference/`, `history/`; README каждого расширения — по
  [шаблону](reference/extension-readme.md). Таблицы из манифестов строит
  `tools/catalog-docs.sh`, CI проверяет их и ссылки (`tools/check-links.sh`).

## Дальше
1. Bisquite 3.0.0 (Task 24–26 плана cream): примеры VMFILE на `RUN_COMMAND cream install`.
2. OpenWrt: несколько пиров у `amneziawg`, `AMNEZIAWG_I1`–`I5`; живая проверка на Raspberry Pi.
3. Бэклог после 5.0.0 — раздел «Бэклог после 5.0.0» плана
   [2026-10-19-cream-v1-migration](plans/2026-10-19-cream-v1-migration.md).
4. Разгрести предупреждения shellcheck вне расширений (планка `make lint` — error).

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
