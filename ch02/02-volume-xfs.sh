#!/usr/bin/env bash
# 02-volume-xfs.sh - BD511 ch.2 : volume XFS dédié (noatime) pour /var/lib/mongodb
# Simule un disque dédié par un fichier image monté en boucle (loop).
# Usage : sudo bash ~/bd511/ch02/02-volume-xfs.sh [taille_en_Go]   (8 Go par défaut)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Lancez ce script avec sudo." >&2; exit 1; }

IMAGE=/var/lib/mongodb-xfs.img
POINT=/var/lib/mongodb
TAILLE_GO=${1:-8}

getent passwd mongodb >/dev/null || { echo "Utilisateur mongodb absent : faites d'abord la partie 1." >&2; exit 1; }
command -v mkfs.xfs >/dev/null || apt-get install -y xfsprogs

if findmnt -n -t xfs "$POINT" >/dev/null; then
  echo "$POINT est déjà un volume XFS monté : rien à faire."
  findmnt "$POINT"
  exit 0
fi

# mongod ne doit pas tourner pendant la préparation du volume.
systemctl stop mongod 2>/dev/null || true

# Le point de montage doit être vide : d'éventuelles données créées sur ext4 sont mises de côté.
if [[ -d $POINT && -n $(ls -A "$POINT") ]]; then
  sauvegarde="$POINT.ext4-$(date +%Y%m%d%H%M%S)"
  echo "Contenu existant de $POINT déplacé vers $sauvegarde"
  mv "$POINT" "$sauvegarde"
fi
mkdir -p "$POINT"

if [[ ! -f $IMAGE ]]; then
  libre=$(df --output=avail -BG "$(dirname "$IMAGE")" | tail -n 1 | tr -dc '0-9')
  (( libre - 3 < TAILLE_GO )) && TAILLE_GO=$(( libre - 3 ))
  (( TAILLE_GO >= 2 )) || { echo "Espace disque insuffisant (${libre} Go libres)." >&2; exit 1; }
  echo "Création de $IMAGE (${TAILLE_GO} Go)..."
  fallocate -l "${TAILLE_GO}G" "$IMAGE"
  chmod 600 "$IMAGE"
fi

if [[ $(blkid -p -s TYPE -o value "$IMAGE" 2>/dev/null || true) != xfs ]]; then
  echo "Formatage XFS..."
  mkfs.xfs -q -f -L mongodata "$IMAGE"
fi

if ! grep -qE "^${IMAGE}[[:space:]]" /etc/fstab; then
  cp /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d%H%M%S)"
  printf '%s\t%s\txfs\tdefaults,loop,noatime,nofail\t0\t0\n' "$IMAGE" "$POINT" >> /etc/fstab
fi

systemctl daemon-reload
mount "$POINT"
chown mongodb:mongodb "$POINT"
chmod 0750 "$POINT"
findmnt "$POINT"
