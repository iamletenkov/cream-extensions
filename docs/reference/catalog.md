# Справочник каталога

Связи всех расширений одной таблицей: какую версию cream требует, что даёт, что
требует, от чего зависит, с чем конфликтует, когда настраивается на загрузке и
ставится ли на живую машину. Что делает расширение и его параметры — таблица в
[README](../../README.md#расширения) и README самого расширения; правила и
происхождение способностей — [способности](capabilities.md).

Всё ниже строит `tools/catalog-docs.sh` из `extension.yaml`; руками не править.
Версии расширений — в их манифестах и в снимке выпуска (`cream source show core`,
`cream list`).

<!-- catalog:reference -->
| Расширение | cream | Даёт | Требует | Зависит от | Конфликтует с | Настройка на загрузке | Живая машина |
|---|---|---|---|---|---|---|---|
| [`amneziawg`](../../extensions/openwrt/amneziawg/README.md) | ≥ 1.3.0 | `vpn-amneziawg` | — | — | — | стадия `system`, на каждой загрузке (`every_boot`) | да |
| [`apt-guard`](../../extensions/debian/apt-guard/README.md) | ≥ 1.0.0 | — | — | — | — | — | да |
| [`btop`](../../extensions/debian/btop/README.md) | ≥ 1.0.0 | `system-monitor` | — | [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | — | да |
| [`can`](../../extensions/debian/can/README.md) | ≥ 1.0.0 | `can-bus` | — | [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | — | да |
| [`can-usb`](../../extensions/debian/can-usb/README.md) | ≥ 1.0.0 | `can-usb-adapters` | `gmsl2-camera` | [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | — | с `--accept-risk` |
| [`chromium-kiosk`](../../extensions/debian/chromium-kiosk/README.md) | ≥ 1.0.0 | `kiosk-browser` | — | [`apt-guard`](../../extensions/debian/apt-guard/README.md) | [`kiosk`](../../extensions/debian/kiosk/README.md) | стадия `system`, по отметке выполнения | с `--accept-risk` |
| [`cloud-growroot`](../../extensions/debian/cloud-growroot/README.md) | ≥ 1.0.0 | `cloud-growroot` | — | — | — | — | нет, только образ |
| [`cloud-user`](../../extensions/debian/cloud-user/README.md) | ≥ 1.0.0 | — | — | — | — | — | да |
| [`cloud-user-desktop`](../../extensions/debian/cloud-user-desktop/README.md) | ≥ 1.0.0 | `cloud-user-desktop` | — | [`desktop`](../../extensions/debian/desktop/README.md), [`cloud-user`](../../extensions/debian/cloud-user/README.md) | — | — | да |
| [`code-server`](../../extensions/debian/code-server/README.md) | ≥ 1.2.0 | `web-ide` | — | [`cloud-user`](../../extensions/debian/cloud-user/README.md), [`fetch`](../../extensions/debian/fetch/README.md) | — | стадия `cloud-user`, на каждой загрузке (`every_boot`) | да |
| [`cuda-toolkit`](../../extensions/debian/cuda-toolkit/README.md) | ≥ 1.0.0 | `cuda` | — | [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | — | да |
| [`desktop`](../../extensions/debian/desktop/README.md) | ≥ 1.2.0 | — | — | [`cloud-user`](../../extensions/debian/cloud-user/README.md) | — | стадия `system`, на каждой загрузке (`every_boot`) | да |
| [`docker`](../../extensions/debian/docker/README.md) | ≥ 1.2.0 | `container-runtime` | — | [`cloud-user`](../../extensions/debian/cloud-user/README.md), [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | стадия `system`, на каждой загрузке (`every_boot`) | с `--accept-risk` |
| [`fetch`](../../extensions/debian/fetch/README.md) | ≥ 1.0.0 | — | — | — | — | — | да |
| [`firefox`](../../extensions/debian/firefox/README.md) | ≥ 1.0.0 | `web-browser` | — | [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | — | да |
| [`firewall`](../../extensions/debian/firewall/README.md) | ≥ 1.2.0 | `host-firewall` | — | — | — | стадия `early`, на каждой загрузке (`every_boot`) | с `--accept-risk` |
| [`gnome`](../../extensions/debian/gnome/README.md) | ≥ 1.0.0 | `x11-server`, `display-manager`, `desktop-session` | — | [`desktop`](../../extensions/debian/desktop/README.md) | способность `desktop-session` | — | с `--accept-risk` |
| [`jetson-stats`](../../extensions/debian/jetson-stats/README.md) | ≥ 1.2.0 | `jetson-monitor` | — | [`cloud-user`](../../extensions/debian/cloud-user/README.md), [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | стадия `cloud-user`, на каждой загрузке (`every_boot`) | да |
| [`kiosk`](../../extensions/debian/kiosk/README.md) | ≥ 1.2.0 | `kiosk-browser` | `x11-server`, `display-manager` | [`cloud-user`](../../extensions/debian/cloud-user/README.md), [`apt-guard`](../../extensions/debian/apt-guard/README.md) | [`chromium-kiosk`](../../extensions/debian/chromium-kiosk/README.md) | стадия `graphical`, на каждой загрузке (`every_boot`) | с `--accept-risk` |
| [`l4t`](../../extensions/debian/l4t/README.md) | ≥ 1.0.0 | — | — | — | — | — | да |
| [`l4t-board-fdt`](../../extensions/debian/l4t-board-fdt/README.md) | ≥ 1.0.0 | `l4t-board-selected` | `l4t-custom-kernel` | — | — | — | с `--accept-risk` |
| [`l4t-boot-verify`](../../extensions/debian/l4t-boot-verify/README.md) | ≥ 1.0.0 | `l4t-boot-verify` | — | — | — | — | да |
| [`l4t-gstreamer`](../../extensions/debian/l4t-gstreamer/README.md) | ≥ 1.0.0 | `gstreamer`, `hw-video-codec` | — | [`l4t`](../../extensions/debian/l4t/README.md), [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | — | да |
| [`l4t-kernel-kvm`](../../extensions/debian/l4t-kernel-kvm/README.md) | ≥ 1.0.0 | `kvm-host`, `l4t-custom-kernel` | — | — | — | — | нет, только образ |
| [`l4t-opencv`](../../extensions/debian/l4t-opencv/README.md) | ≥ 1.0.0 | `opencv` | — | [`l4t`](../../extensions/debian/l4t/README.md), [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | — | да |
| [`l4t-pytorch`](../../extensions/debian/l4t-pytorch/README.md) | ≥ 1.0.0 | `pytorch` | `cuda` | [`l4t`](../../extensions/debian/l4t/README.md), [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | — | да |
| [`l4t-tensorflow`](../../extensions/debian/l4t-tensorflow/README.md) | ≥ 1.0.0 | `tensorflow` | `cuda` | [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | — | да |
| [`l4t-vendor-desktop`](../../extensions/debian/l4t-vendor-desktop/README.md) | ≥ 1.0.0 | `x11-server`, `display-manager`, `desktop-session` | — | — | способность `desktop-session` | — | да |
| [`locale`](../../extensions/debian/locale/README.md) | ≥ 1.0.0 | `system-locale` | — | — | — | — | да |
| [`luci-apps`](../../extensions/openwrt/luci-apps/README.md) | ≥ 1.3.0 | — | — | — | — | — | да |
| [`lxde`](../../extensions/debian/lxde/README.md) | ≥ 1.0.0 | `x11-server`, `display-manager`, `desktop-session` | — | [`desktop`](../../extensions/debian/desktop/README.md) | способность `desktop-session` | — | с `--accept-risk` |
| [`network-manager`](../../extensions/debian/network-manager/README.md) | ≥ 1.0.0 | `network-manager` | — | [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | — | с `--accept-risk` |
| [`nocloud-cidata`](../../extensions/debian/nocloud-cidata/README.md) | ≥ 1.0.0 | `nocloud-cidata-seed` | — | — | — | — | нет, только образ |
| [`nvidia`](../../extensions/debian/nvidia/README.md) | ≥ 1.0.0 | `gpu-driver-nvidia` | — | — | — | — | с `--accept-risk` |
| [`nvidia-container-toolkit`](../../extensions/debian/nvidia-container-toolkit/README.md) | ≥ 1.0.0 | `nvidia-container-runtime` | `container-runtime`, `gpu-driver-nvidia` | [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | — | с `--accept-risk` |
| [`nvidia-jetpack`](../../extensions/debian/nvidia-jetpack/README.md) | ≥ 1.0.0 | `jetson-flash-station` | — | [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | — | с `--accept-risk` |
| [`pixelflux-tegra`](../../extensions/debian/pixelflux-tegra/README.md) | ≥ 1.2.0 | — | `web-remote-desktop` | [`cloud-user`](../../extensions/debian/cloud-user/README.md) | [`pixelflux-v4l2m2m`](../../extensions/debian/pixelflux-v4l2m2m/README.md) | стадия `graphical`, на каждой загрузке (`every_boot`) | да |
| [`pixelflux-v4l2m2m`](../../extensions/debian/pixelflux-v4l2m2m/README.md) | ≥ 1.2.0 | `hardware-video-encoding` | `web-remote-desktop` | — | [`pixelflux-tegra`](../../extensions/debian/pixelflux-tegra/README.md) | стадия `graphical`, на каждой загрузке (`every_boot`) | да |
| [`podkop`](../../extensions/openwrt/podkop/README.md) | ≥ 1.3.0 | `selective-routing` | — | — | — | стадия `system`, по отметке выполнения | да |
| [`rustdesk`](../../extensions/debian/rustdesk/README.md) | ≥ 1.2.0 | `remote-support` | — | [`cloud-user`](../../extensions/debian/cloud-user/README.md), [`apt-guard`](../../extensions/debian/apt-guard/README.md), [`fetch`](../../extensions/debian/fetch/README.md) | — | стадия `system`, на каждой загрузке (`every_boot`) | да |
| [`selkies`](../../extensions/debian/selkies/README.md) | ≥ 1.2.0 | `web-remote-desktop` | `x11-server`, `display-manager` | [`cloud-user`](../../extensions/debian/cloud-user/README.md), [`fetch`](../../extensions/debian/fetch/README.md) | — | стадия `graphical`, на каждой загрузке (`every_boot`) | да |
| [`sensing-gmsl2-camera`](../../extensions/debian/sensing-gmsl2-camera/README.md) | ≥ 1.0.0 | `gmsl2-camera` | — | [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | — | с `--accept-risk` |
| [`stvor-agent`](../../extensions/debian/stvor-agent/README.md) | ≥ 1.0.0 | `stvor-agent` | — | [`teleport`](../../extensions/debian/teleport/README.md) | — | — | да |
| [`teleport`](../../extensions/debian/teleport/README.md) | ≥ 1.0.0 | `teleport-node` | — | — | способность `teleport-node` | — | да |
| [`tensorrt`](../../extensions/debian/tensorrt/README.md) | ≥ 1.0.0 | `tensorrt` | — | [`l4t`](../../extensions/debian/l4t/README.md), [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | — | да |
| [`vino-vnc`](../../extensions/debian/vino-vnc/README.md) | ≥ 1.2.0 | `remote-desktop` | `x11-server`, `display-manager` | [`cloud-user`](../../extensions/debian/cloud-user/README.md), [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | стадия `system`, на каждой загрузке (`every_boot`) | да |
| [`wallpaper`](../../extensions/debian/wallpaper/README.md) | ≥ 1.1.1 | `wallpaper` | `desktop-session` | [`cloud-user`](../../extensions/debian/cloud-user/README.md) | — | стадия `cloud-user`, по отметке выполнения | да |
| [`x11vnc`](../../extensions/debian/x11vnc/README.md) | ≥ 1.2.0 | `remote-desktop` | `x11-server`, `display-manager` | [`cloud-user`](../../extensions/debian/cloud-user/README.md), [`apt-guard`](../../extensions/debian/apt-guard/README.md) | — | стадия `graphical`, на каждой загрузке (`every_boot`) | да |
| [`xfce4`](../../extensions/debian/xfce4/README.md) | ≥ 1.0.0 | `x11-server`, `display-manager`, `desktop-session` | — | [`desktop`](../../extensions/debian/desktop/README.md) | способность `desktop-session` | — | с `--accept-risk` |
| [`yq`](../../extensions/debian/yq/README.md) | ≥ 1.0.0 | `yq` | — | — | — | — | да |

### Способности: кто даёт и кто требует

| Способность | Дают | Требуют |
|---|---|---|
| `can-bus` | [`can`](../../extensions/debian/can/README.md) | — |
| `can-usb-adapters` | [`can-usb`](../../extensions/debian/can-usb/README.md) | — |
| `cloud-growroot` | [`cloud-growroot`](../../extensions/debian/cloud-growroot/README.md) | — |
| `cloud-user-desktop` | [`cloud-user-desktop`](../../extensions/debian/cloud-user-desktop/README.md) | — |
| `container-runtime` | [`docker`](../../extensions/debian/docker/README.md) | [`nvidia-container-toolkit`](../../extensions/debian/nvidia-container-toolkit/README.md) |
| `cuda` | [`cuda-toolkit`](../../extensions/debian/cuda-toolkit/README.md) | [`l4t-pytorch`](../../extensions/debian/l4t-pytorch/README.md), [`l4t-tensorflow`](../../extensions/debian/l4t-tensorflow/README.md) |
| `desktop-session` | [`gnome`](../../extensions/debian/gnome/README.md), [`l4t-vendor-desktop`](../../extensions/debian/l4t-vendor-desktop/README.md), [`lxde`](../../extensions/debian/lxde/README.md), [`xfce4`](../../extensions/debian/xfce4/README.md) | [`wallpaper`](../../extensions/debian/wallpaper/README.md) |
| `display-manager` | [`gnome`](../../extensions/debian/gnome/README.md), [`l4t-vendor-desktop`](../../extensions/debian/l4t-vendor-desktop/README.md), [`lxde`](../../extensions/debian/lxde/README.md), [`xfce4`](../../extensions/debian/xfce4/README.md) | [`kiosk`](../../extensions/debian/kiosk/README.md), [`selkies`](../../extensions/debian/selkies/README.md), [`vino-vnc`](../../extensions/debian/vino-vnc/README.md), [`x11vnc`](../../extensions/debian/x11vnc/README.md) |
| `gmsl2-camera` | [`sensing-gmsl2-camera`](../../extensions/debian/sensing-gmsl2-camera/README.md) | [`can-usb`](../../extensions/debian/can-usb/README.md) |
| `gpu-driver-nvidia` | [`nvidia`](../../extensions/debian/nvidia/README.md) | [`nvidia-container-toolkit`](../../extensions/debian/nvidia-container-toolkit/README.md) |
| `gstreamer` | [`l4t-gstreamer`](../../extensions/debian/l4t-gstreamer/README.md) | — |
| `hardware-video-encoding` | [`pixelflux-v4l2m2m`](../../extensions/debian/pixelflux-v4l2m2m/README.md) | — |
| `host-firewall` | [`firewall`](../../extensions/debian/firewall/README.md) | — |
| `hw-video-codec` | [`l4t-gstreamer`](../../extensions/debian/l4t-gstreamer/README.md) | — |
| `jetson-flash-station` | [`nvidia-jetpack`](../../extensions/debian/nvidia-jetpack/README.md) | — |
| `jetson-monitor` | [`jetson-stats`](../../extensions/debian/jetson-stats/README.md) | — |
| `kiosk-browser` | [`chromium-kiosk`](../../extensions/debian/chromium-kiosk/README.md), [`kiosk`](../../extensions/debian/kiosk/README.md) | — |
| `kvm-host` | [`l4t-kernel-kvm`](../../extensions/debian/l4t-kernel-kvm/README.md) | — |
| `l4t-board-selected` | [`l4t-board-fdt`](../../extensions/debian/l4t-board-fdt/README.md) | — |
| `l4t-boot-verify` | [`l4t-boot-verify`](../../extensions/debian/l4t-boot-verify/README.md) | — |
| `l4t-custom-kernel` | [`l4t-kernel-kvm`](../../extensions/debian/l4t-kernel-kvm/README.md) | [`l4t-board-fdt`](../../extensions/debian/l4t-board-fdt/README.md) |
| `network-manager` | [`network-manager`](../../extensions/debian/network-manager/README.md) | — |
| `nocloud-cidata-seed` | [`nocloud-cidata`](../../extensions/debian/nocloud-cidata/README.md) | — |
| `nvidia-container-runtime` | [`nvidia-container-toolkit`](../../extensions/debian/nvidia-container-toolkit/README.md) | — |
| `opencv` | [`l4t-opencv`](../../extensions/debian/l4t-opencv/README.md) | — |
| `pytorch` | [`l4t-pytorch`](../../extensions/debian/l4t-pytorch/README.md) | — |
| `remote-desktop` | [`vino-vnc`](../../extensions/debian/vino-vnc/README.md), [`x11vnc`](../../extensions/debian/x11vnc/README.md) | — |
| `remote-support` | [`rustdesk`](../../extensions/debian/rustdesk/README.md) | — |
| `selective-routing` | [`podkop`](../../extensions/openwrt/podkop/README.md) | — |
| `stvor-agent` | [`stvor-agent`](../../extensions/debian/stvor-agent/README.md) | — |
| `system-locale` | [`locale`](../../extensions/debian/locale/README.md) | — |
| `system-monitor` | [`btop`](../../extensions/debian/btop/README.md) | — |
| `teleport-node` | [`teleport`](../../extensions/debian/teleport/README.md) | — |
| `tensorflow` | [`l4t-tensorflow`](../../extensions/debian/l4t-tensorflow/README.md) | — |
| `tensorrt` | [`tensorrt`](../../extensions/debian/tensorrt/README.md) | — |
| `vpn-amneziawg` | [`amneziawg`](../../extensions/openwrt/amneziawg/README.md) | — |
| `wallpaper` | [`wallpaper`](../../extensions/debian/wallpaper/README.md) | — |
| `web-browser` | [`firefox`](../../extensions/debian/firefox/README.md) | — |
| `web-ide` | [`code-server`](../../extensions/debian/code-server/README.md) | — |
| `web-remote-desktop` | [`selkies`](../../extensions/debian/selkies/README.md) | [`pixelflux-tegra`](../../extensions/debian/pixelflux-tegra/README.md), [`pixelflux-v4l2m2m`](../../extensions/debian/pixelflux-v4l2m2m/README.md) |
| `x11-server` | [`gnome`](../../extensions/debian/gnome/README.md), [`l4t-vendor-desktop`](../../extensions/debian/l4t-vendor-desktop/README.md), [`lxde`](../../extensions/debian/lxde/README.md), [`xfce4`](../../extensions/debian/xfce4/README.md) | [`kiosk`](../../extensions/debian/kiosk/README.md), [`selkies`](../../extensions/debian/selkies/README.md), [`vino-vnc`](../../extensions/debian/vino-vnc/README.md), [`x11vnc`](../../extensions/debian/x11vnc/README.md) |
| `yq` | [`yq`](../../extensions/debian/yq/README.md) | — |
<!-- /catalog:reference -->
