# 04. Живые прогоны и разбор падений

L-прогон — настоящий cream по пину в контейнере с systemd как PID 1
(`tools/live-test.sh`): install, повтор, `--reinstall` без изменений файлов,
перезагрузка (configure на загрузке, `systemctl --failed` пуст, нет ordering cycle),
секреты не утекают, remove. L-расширение — то, у которого есть `tests/live.env`.

## Запуск

Хост общий: один прогон за раз (замок `flock` в раннере), перед тяжёлым — память.
```sh
free -g                                                   # available ≥ 6 ГБ
make test-live EXT=<имя>                                  # debian-12
make test-live EXT=<имя> DISTRO=ubuntu-24.04              # другой дистрибутив
make test-live EXT=<имя> ARGS='--cap NET_ADMIN --param K=V'
gh workflow run live.yml -f ext=<имя>                     # то же в CI (пусто — все)
```
Умолчания прогона — `tests/live.env` расширения (данные, не скрипт): `LIVE_DISTROS`,
`LIVE_DEPS`, `LIVE_ACCEPT_RISK`, `LIVE_EXPECT_SKIP`, `LIVE_PARAMS`, `LIVE_SECRETS`,
`LIVE_MEMORY`, `LIVE_CAPS`, `LIVE_SNAPSHOT_IGNORE`, `LIVE_BOOT_CONFIGURE`,
`LIVE_FAILED_IGNORE`. Флаги перекрывают файл.

## Разбор падения

1. Итог — последняя строка: `проверок N, не прошло M; журналы — .scratchpad/live/<ext>-<distro>`.
2. Какая проверка: строки `FAIL` в выводе; полный журнал установки, журнал загрузки и
   `systemctl --failed` — в каталоге журналов.
3. Классифицировать:
   - **расширение** — хук отказал, файл изменился при `--reinstall`, юнит упал, `remove`
     отказал (пример: на Ubuntu apt ставит рекомендации, зависящие от пакета, и
     `apt-guard` в `remove` отказывает) — чинить хук, H-тест на случай — первым;
   - **стенд** — юнит, которого расширение не ставит и не трогает, падает в контейнере
     (polkit, systemd-hostnamed без `CAP_SYS_ADMIN`) — `LIVE_FAILED_IGNORE="^(…)\.service$"`
     в `tests/live.env` с причиной в комментарии;
   - **окружение** — сеть, apt-зеркало, нехватка памяти/диска, `systemd в контейнере не
     загрузился` — повторить; `--cap SYS_ADMIN` с профилем AppArmor `docker-default`
     systemd не загружает, `apparmor=unconfined` на общем хосте не используется.
4. Повторить прогон того же дистрибутива; затем остальные из `LIVE_DISTROS`.

## Проверка результата

`проверок N, не прошло 0` на каждом дистрибутиве `LIVE_DISTROS`; на PR — зелёный `live.yml`.
README расширения, раздел «Проверки» (L), называет дистрибутивы и разрешённые падения.
