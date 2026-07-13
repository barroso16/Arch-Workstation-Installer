# Instalacion en M.2 real

Esta guia es para instalar Arch Workstation Installer en un NVMe/M.2 real
despues de la prueba completa en VMware.

No se puede prometer cero errores en hardware real. Antes del particionado, el
equipo puede depender de WiFi real, GPU NVIDIA/AMD, modo BIOS/UEFI, Intel
RST/RAID, Secure Boot y otros discos conectados. El flujo del instalador si fue
probado de punta a punta en VMware con Hyprland/Waybar y la personalizacion
Omarchy-style.

## BIOS/UEFI

Configura el firmware antes de arrancar el ISO:

- UEFI activado.
- Secure Boot desactivado por ahora.
- Fast Boot desactivado.
- Intel RST/RAID desactivado; usar AHCI/NVMe normal.
- Para maquinas virtuales, activar Intel VT-x/VT-d o AMD-V/AMD-Vi si BIOS ofrece
  esas opciones. No son necesarias para arrancar Hyprland, pero si para KVM.
- En este portatil Intel + RTX 3060, usar `Discrete Graphics`/`dGPU only` si
  BIOS lo ofrece y quieres que Hyprland trabaje siempre sobre NVIDIA. Si esa
  opcion no existe, mantener modo hibrido y usar PRIME para las cargas pesadas.
- Si hay otros discos conectados, confirmar visualmente cual es el M.2 objetivo.

## Live ISO

Arranca desde el ISO oficial de Arch Linux y sincroniza la hora:

```bash
timedatectl set-ntp true
```

Conecta internet. Para cable normalmente basta con comprobar:

```bash
ping -c 3 archlinux.org
```

Para WiFi:

```bash
rfkill unblock wifi
systemctl start iwd
iwctl
```

Dentro de `iwctl`:

```text
device list
station wlan0 scan
station wlan0 get-networks
station wlan0 connect "TU_WIFI"
exit
```

Si la interfaz no es `wlan0`, usa el nombre que salga en `device list`.

## Descargar instalador

```bash
pacman -Sy --needed git
git clone https://github.com/barroso16/Arch-Workstation-Installer.git
cd Arch-Workstation-Installer
```

Identifica el M.2:

```bash
lsblk -o NAME,SIZE,TYPE,MODEL
```

Normalmente sera `/dev/nvme0n1`, pero no lo asumas. Confirma modelo y tamano
antes de escribir `TARGET_DISK`.

## Configuracion para primera instalacion

Edita:

```bash
nano configs/install.conf
```

Valores recomendados para esta primera pasada en hardware real:

```bash
USERNAME=scooby
TARGET_DISK=/dev/nvme0n1
INSTALL_DESKTOP_ENV=hyprland
INSTALL_NVIDIA_IF_DETECTED=yes
INSTALL_AMD_IF_DETECTED=yes
NVIDIA_DRIVER=auto
ENABLE_SECURE_BOOT=no
SBCTL_CREATE_KEYS=no
SBCTL_ENROLL_MICROSOFT_KEYS=no
```

Si el M.2 correcto no es `/dev/nvme0n1`, cambia `TARGET_DISK` por el disco real.
No uses una particion como `/dev/nvme0n1p1`; debe ser el disco completo.

Para NVIDIA, deja `INSTALL_NVIDIA_IF_DETECTED=yes`. El modo recomendado es
`NVIDIA_DRIVER=auto`: usa `nvidia-open-dkms` en Turing/GTX16/RTX y posteriores.
La RTX 3060 Laptop de este equipo entra en esa ruta. GTX 10xx/Pascal y tarjetas
anteriores se detienen con un error explicito porque Arch actual exige un driver
legacy desde AUR; el instalador no intentara colocarles un driver incompatible.

## Ejecucion por stages

Ejecuta los stages manualmente y deten la instalacion ante cualquier error:

```bash
bash scripts/stage01-preflight.sh
bash scripts/stage02-storage.sh
bash scripts/stage03-storage.sh
bash scripts/stage03-bootstrap.sh
bash scripts/stage04-base-config.sh
bash scripts/stage05-bootloader.sh
bash scripts/stage06-system.sh
bash scripts/stage07-hardening.sh
bash scripts/stage08-finalize.sh
```

`stage03-storage.sh` es destructivo. Antes de confirmarlo, revisa una vez mas
`lsblk -o NAME,SIZE,TYPE,MODEL`.

No uses scripts antiguos de compatibilidad como sustituto del flujo anterior.
El orden recomendado para esta instalacion es el listado arriba.

## Reinicio

Si Stage08 termina con `FAIL: 0`, reinicia:

```bash
reboot
```

Quita el USB/ISO para arrancar desde el M.2.

Dentro del sistema instalado:

```bash
systemctl --failed
nmcli device status
ping -c 3 archlinux.org
```

Si el equipo tiene NVIDIA:

```bash
nvidia-smi
cat /sys/module/nvidia_drm/parameters/modeset
prime-run glxinfo -B
systemctl status nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service
```

`modeset` debe devolver `Y`. Si Hyprland no abre, entra por TTY con
`Ctrl+Alt+F2`, inicia sesion y revisa:

```bash
journalctl -b -u sddm --no-pager
journalctl -b | grep -iE 'nvidia|hyprland|drm'
```

En modo hibrido, Hyprland puede usar Intel para la pantalla y la RTX para juegos
o trabajo pesado. Ejecuta esas aplicaciones con `prime-run programa`. No fuerces
`AQ_DRM_DEVICES` antes del primer arranque: las rutas dependen del cableado real
del portatil y una seleccion incorrecta puede dejar la pantalla interna negra.

No pruebes hibernacion hasta confirmar varios reinicios y suspensiones normales.
Early KMS mejora el arranque grafico, pero en algunos equipos puede impedir que
la hibernacion reanude correctamente.

Si el equipo tiene una GPU AMD Radeon moderna, el instalador la detecta y usa
el modulo `amdgpu` del kernel junto con Mesa/RADV. No aplica las variables NVIDIA
ni fuerza modulos adicionales en mkinitcpio. Despues del primer arranque revisa:

```bash
glxinfo -B | grep -E 'OpenGL vendor|OpenGL renderer'
vulkaninfo --summary
vainfo
radeontop
```

El renderer debe mostrar AMD/Radeon y Vulkan debe mostrar el driver RADV. En
graficas ATI/AMD muy antiguas puede ser necesaria una configuracion especifica
del kernel; la ruta automatica esta orientada a Radeon compatibles con `amdgpu`.

## Procesadores Intel y AMD

El instalador soporta procesadores x86_64 Intel y AMD. Detecta el fabricante y
solo instala su microcodigo correspondiente:

- Intel Core, Core Ultra y Xeon: `intel-ucode`.
- AMD Ryzen, Threadripper y EPYC: `amd-ucode`.

Stage01 valida que el paquete exista antes de tocar el disco y Stage08 comprueba
que el microcodigo quedo dentro de `initramfs-linux.img`. Despues de arrancar:

```bash
lscpu | grep -E 'Vendor ID|Model name|Virtualization'
journalctl -k -b | grep -i microcode
lsmod | grep -E '^kvm|kvm_intel|kvm_amd'
```

Si `Virtualization` no aparece pero el procesador la soporta, habilitala en
BIOS/UEFI. CPUs ARM, Apple Silicon y otros fabricantes no estan cubiertos por
este instalador x86_64.

## Aplicaciones incluidas

Con los perfiles predeterminados se instala un escritorio utilizable desde el
primer arranque: Firefox y Chromium, Nautilus, Kitty, Wofi, Waybar, Hyprlock,
NetworkManager, PipeWire, Bluetooth, CUPS, herramientas multimedia, desarrollo,
virtualizacion, contenedores y utilidades de terminal.

Stage01 consulta cada paquete en Pacman antes del particionado. Si un paquete no
existe o los repositorios no estan sincronizados, se detiene sin borrar el M.2.
Tras arrancar puedes comprobar los componentes principales con:

```bash
command -v firefox chromium nautilus kitty hyprlock nmcli
systemctl --failed
systemctl is-enabled NetworkManager bluetooth cups sddm
pactl info
```

## Personalizacion Omarchy-style

Ya dentro de Arch instalado y con sesion grafica:

```bash
cd ~
git clone https://github.com/barroso16/Arch-Workstation-Installer.git
cd Arch-Workstation-Installer
sudo bash scripts/omarchy-redteam-customize.sh --target-root / --user scooby
```

El script enumera temas por numero, abre una preview obligatoria y pide
confirmacion antes de aplicar.

## Nota VMware

Si en VMware el escritorio queda negro con Waybar visible, Hyprland esta vivo.
Prueba `Super + Enter` para terminal y `Super + Space` para menu.
