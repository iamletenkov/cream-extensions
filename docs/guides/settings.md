# Настройки на работающей машине

Устройство уже работает — как поменять настройку расширения и чем её применить.
Ответ один на все расширения: `cream show` и `cream set` по домену расширения.

```bash
cream show x11vnc                                    # ключи, значения, умолчания; секреты — маской
sudo cream set x11vnc X11VNC_LISTEN=all              # проверка по схеме, атомарная запись, хук apply
echo 'пароль' | sudo cream set x11vnc X11VNC_PASSWORD=-   # секрет — со stdin или --params-file, не в argv
sudo cream set --no-apply desktop DESKTOP_AUTOLOGIN=1     # только записать, применить позже
```

- Схема — `config.keys` манифеста; ключи и их типы — раздел «Параметры» README
  расширения. Неверное значение отвергается до записи.
- Файл настроек — `/etc/cream/<имя>/config` (`KEY=VALUE`, грамматика systemd
  `EnvironmentFile`), секреты — отдельно в `/etc/cream/<имя>/secrets` (0600).
  Руками их не правят: `cream set` проверяет значение и зовёт хук.
- Ключи «только при установке» (`scope: install`: версии и суммы скачиваемого)
  задаются в самой установке: `sudo cream install --reinstall <имя> KEY=VALUE`.
- Ручки рабочего стола (автологин, блокировка, затемнение) — домен расширения
  `desktop`, общий для `gnome`, `xfce4`, `lxde` и `cloud-user-desktop`.

## Когда правка действует

| Расширение | Ключей | Когда правка действует |
|---|---|---|
| `can` | 1 | хук `apply` сразу после `cream set` |
| `chromium-kiosk` | 16 | перезапуск `configure` сразу после `cream set` (своего `apply` нет; на загрузке — стадия `system`) |
| `cloud-user-desktop` | 1 | при установке (`cream install --reinstall <имя> KEY=VALUE`) |
| `code-server` | 5, из них секретов 1 | хук `apply` сразу после `cream set` |
| `desktop` | 4 | перезапуск `configure` сразу после `cream set` (своего `apply` нет; на загрузке — стадия `system`) |
| `firefox` | 1 | при установке (`cream install --reinstall <имя> KEY=VALUE`) |
| `firewall` | 3 | перезапуск `configure` сразу после `cream set` (своего `apply` нет; на загрузке — стадия `early`) |
| `jetson-stats` | 1 | перезапуск `configure` сразу после `cream set` (своего `apply` нет; на загрузке — стадия `cloud-user`) |
| `kiosk` | 5 | перезапуск `configure` сразу после `cream set` (своего `apply` нет; на загрузке — стадия `graphical`) |
| `l4t-board-fdt` | 1 | при установке (`cream install --reinstall <имя> KEY=VALUE`) |
| `l4t-gstreamer` | 1 | при установке (`cream install --reinstall <имя> KEY=VALUE`) |
| `l4t-kernel-kvm` | 5 | при установке (`cream install --reinstall <имя> KEY=VALUE`) |
| `l4t-pytorch` | 1 | при установке (`cream install --reinstall <имя> KEY=VALUE`) |
| `locale` | 3 | хук `apply` сразу после `cream set` |
| `nvidia-container-toolkit` | 1 | при установке (`cream install --reinstall <имя> KEY=VALUE`) |
| `nvidia` | 3 | при установке (`cream install --reinstall <имя> KEY=VALUE`) |
| `rustdesk` | 9 | перезапуск `configure` сразу после `cream set` (своего `apply` нет; на загрузке — стадия `system`) |
| `selkies` | 29, из них секретов 3 | хук `apply` сразу после `cream set` |
| `sensing-gmsl2-camera` | 3 | хук `apply` сразу после `cream set` |
| `stvor-agent` | 6 | хук `apply` сразу после `cream set` |
| `teleport` | 17 | хук `apply` сразу после `cream set` |
| `vino-vnc` | 5, из них секретов 1 | перезапуск `configure` сразу после `cream set` (своего `apply` нет; на загрузке — стадия `system`) |
| `wallpaper` | 2 | перезапуск `configure` сразу после `cream set` (своего `apply` нет; на загрузке — стадия `cloud-user`) |
| `x11vnc` | 5, из них секретов 1 | хук `apply` сразу после `cream set` |
| `yq` | 2 | при установке (`cream install --reinstall <имя> KEY=VALUE`) |

Остальные расширения настроек не имеют. Как применилась правка, `cream set`
печатает сам (`применение: hook | restart | none`); `cream set --wait` дожидается
исхода перезапуска `configure`. Точнее — README расширения (что делает
`apply` по каждому ключу). `/etc/cream/teleport/apps.d/` — не настройки домена, а
объявления других расширений для Teleport.

## Открыть службу в сеть — отдельное решение

Умолчания прослушивания осознанно локальные (`localhost` у `x11vnc` и `vino-vnc`,
`127.0.0.1` у `selkies`). Меняя их, проверьте, чем закрыт доступ: у `code-server`
связка `CODE_SERVER_BIND=0.0.0.0` с пустым паролем отдала бы в сеть шелл под
пользователем, который обычно состоит в группе `sudo`, — то есть машину целиком.

Две альтернативы без открытия порта:

- **Веб-приложение Teleport** (расширение `teleport`): служба остаётся на петле, а
  расширение кладёт объявление в `/etc/cream/teleport/apps.d/<имя>.conf` — `NAME`,
  `URI` на петле и при нужде `ICON`. Кому приложение видно, решает метка `env`
  оператора, а не объявление; формат — [README teleport](../../extensions/debian/teleport/README.md).
- **Туннель** — без кластера и без правки конфигурации:

  ```bash
  ssh -L 9001:127.0.0.1:9001 <пользователь>@<машина>
  ```
