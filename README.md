# Arch Workstation Installer

Instalador modular para preparar una estación de trabajo profesional basada en
Arch Linux usando el método oficial y scripts auditables.

El proyecto evita asistentes gráficos y no usa `archinstall`. Cada etapa es
independiente, revisable y ejecutable manualmente desde el Arch Linux Live ISO.

## Características

- Instalación base con `pacstrap`, `genfstab` y `arch-chroot`.
- Arranque UEFI con `systemd-boot`.
- Cifrado LUKS2 y sistema de archivos Btrfs.
- Subvolúmenes Btrfs para root, home, var, logs, cache y snapshots.
- Secure Boot con `sbctl`.
- Soporte para kernels `linux` y `linux-lts`.
- Validaciones conservadoras antes de acciones destructivas.
- Flujo por etapas para facilitar revisión, pausa y recuperación.

## Arquitectura

El instalador se divide en librerías reutilizables y stages ejecutables.

Las librerías viven en `scripts/lib/` y contienen funciones comunes para
logging, configuración, hardware, disco, paquetes, chroot, bootloader, Secure
Boot y verificación.

Los stages viven en `scripts/` y ejecutan pasos concretos del proceso. Cada
stage carga solo las librerías que necesita y no llama automáticamente al stage
siguiente.

## Requisitos

- Arch Linux Live ISO oficial.
- Arranque en modo UEFI.
- Conexión de red para `pacstrap`.
- Disco objetivo dedicado.
- Privilegios root.
- Paquetes disponibles en el Live ISO: `pacstrap`, `genfstab`, `arch-chroot`,
  `cryptsetup`, `btrfs-progs`, `bootctl`, `findmnt`, `lsblk` y herramientas base.

## Estructura del proyecto

```text
configs/
  install.conf
profiles/
  *.pkglist
scripts/
  install.sh
  stage01-preflight.sh
  stage02-storage.sh
  stage03-bootstrap.sh
  stage04-base-config.sh
  stage05-secureboot.sh
  stage06-system.sh
  stage07-hardening.sh
  stage08-finalize.sh
  lib/
```

## Instalación

1. Arranca desde el Arch Linux Live ISO en modo UEFI.
2. Conecta la red.
3. Clona o copia este proyecto al entorno Live.
4. Revisa `configs/install.conf`.
5. Ejecuta el orquestador:

```bash
bash scripts/install.sh
```

También puedes ejecutar cada stage manualmente:

```bash
bash scripts/stage01-preflight.sh
```

## Flujo de instalación

1. `stage01-preflight.sh`: validaciones iniciales y resumen de hardware.
2. `stage02-storage.sh`: particionado, LUKS2, Btrfs y montaje en `/mnt`.
3. `stage03-bootstrap.sh`: `pacstrap`, `fstab`, `crypttab` y estado mínimo.
4. `stage04-base-config.sh`: configuración base, usuario, mkinitcpio y systemd-boot.
5. `stage05-secureboot.sh`: claves, enrolamiento, firma y hooks con `sbctl`.
6. `stage06-system.sh`: servicios y ajustes del sistema ya instalado.
7. `stage07-hardening.sh`: comprobaciones de hardening sin instalar paquetes.
8. `stage08-finalize.sh`: verificación final e instrucciones de reinicio.

## Configuración

El archivo principal es `configs/install.conf`.

Variables principales:

- `HOSTNAME`: nombre del sistema instalado.
- `USERNAME`: usuario principal.
- `TIMEZONE`: zona horaria.
- `LOCALE`: locale principal.
- `KEYMAP`: mapa de teclado de consola.
- `TARGET_DISK`: disco objetivo. Déjalo vacío para selección interactiva.
- `EFI_SIZE`: tamaño de la partición EFI.
- `CRYPT_NAME`: nombre del mapper LUKS.
- `BTRFS_COMPRESS`: compresión Btrfs.

## Profiles

Las listas de paquetes viven en `profiles/*.pkglist`.

Cada archivo debe contener un paquete por línea. Las líneas vacías y comentarios
son ignorados.

Los perfiles se activan desde `configs/install.conf`. La lista final se genera
en `state/packages-final.txt` durante Stage03.

## Secure Boot

Secure Boot se gestiona únicamente en Stage05 con `sbctl`.

El flujo previsto es:

- Crear claves si `SBCTL_CREATE_KEYS=yes`.
- Enrolar claves solo con confirmación explícita.
- Incluir Microsoft keys solo si `SBCTL_ENROLL_MICROSOFT_KEYS=yes`.
- Firmar `systemd-boot`, kernels y binarios EFI relevantes.
- Instalar hooks de refirma.
- Verificar con `sbctl status` y `sbctl verify`.

El instalador no desactiva Secure Boot permanentemente.

## Btrfs

El layout Btrfs usa estos subvolúmenes:

- `@`
- `@home`
- `@var`
- `@log`
- `@cache`
- `@snapshots`

Las opciones de montaje se definen desde `BTRFS_COMPRESS`.

## LUKS2

Stage02 crea un contenedor LUKS2 sobre la partición Linux principal y lo abre
como `/dev/mapper/${CRYPT_NAME}`.

Stage03 guarda la entrada correspondiente en `/mnt/etc/crypttab` usando el UUID
del volumen LUKS.

## Snapshots

El layout reserva el subvolumen `@snapshots` para Snapper.

La configuración y verificación de Snapper se hacen en etapas posteriores sin
crear snapshots automáticamente durante el particionado.

## Virtualización

El instalador contempla soporte para QEMU, libvirt, OVMF y TPM virtual cuando el
perfil correspondiente está activado.

Stage06 habilita servicios y grupos solo si los componentes ya están instalados.

## Troubleshooting

- Si Stage02 detecta que `/mnt` ya está montado, desmonta manualmente antes de
  continuar.
- Si `TARGET_DISK` está vacío, Stage02 pedirá el disco exacto.
- Si un disco parece USB/removible, el instalador lo advierte claramente.
- Si `sbctl verify` falla, revisa Stage05 antes de reiniciar.
- Si una etapa falla, corrige la causa y vuelve a ejecutar esa etapa.

## FAQ

**¿Usa archinstall?**  
No.

**¿El instalador reinicia automáticamente?**  
No.

**¿Stage02 borra discos sin confirmación?**  
No. Exige confirmación exacta del disco.

**¿Puedo ejecutar los stages uno por uno?**  
Sí. Ese es el flujo recomendado para auditoría y revisión.

## Contribuir

Mantén cada cambio limitado a una librería o stage. Evita duplicar lógica ya
existente en `scripts/lib/`.

Antes de proponer cambios, revisa que no se mezclen responsabilidades entre
stages y que las acciones destructivas sigan protegidas por confirmación exacta.

## Licencia

Pendiente de definir.
