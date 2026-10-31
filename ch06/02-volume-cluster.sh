#!/usr/bin/env bash
# 02-volume-cluster.sh - BD511 ch.6 : volume XFS dédié (noatime) aux données du cluster Docker
# Simule un disque dédié par un fichier image monté en boucle sur /srv/bd511, puis crée un
# répertoire de données par mongod de l'architecture (colonne « répertoire »).
# Usage : sudo bash ~/bd511/ch06/02-volume-cluster.sh ~/bd511/cluster/architecture.tsv [taille_en_Go]
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Lancez ce script avec sudo." >&2; exit 1; }

ARCHI=${1:?"chemin de architecture.tsv attendu"}
TAILLE_GO=${2:-4}
IMAGE=/var/lib/bd511-cluster-xfs.img
POINT=/srv/bd511
UID_MONGODB=999      # utilisateur mongodb de l'image officielle mongo (uid et gid 999)

[[ -r $ARCHI ]] || { echo "Fichier introuvable : $ARCHI" >&2; exit 1; }
command -v mkfs.xfs >/dev/null || apt-get install -y xfsprogs

if ! findmnt -n -t xfs "$POINT" >/dev/null; then
  mkdir -p "$POINT"
  [[ -z $(ls -A "$POINT") ]] || { echo "$POINT n'est pas vide : abandon." >&2; exit 1; }
  if [[ ! -f $IMAGE ]]; then
    libre=$(df --output=avail -BG "$(dirname "$IMAGE")" | tail -n 1 | tr -dc '0-9')
    (( libre - 2 >= TAILLE_GO )) || { echo "Espace disque insuffisant : ${libre} Go libres, $((TAILLE_GO + 2)) Go requis." >&2; exit 1; }
    echo "Création de $IMAGE (${TAILLE_GO} Go)..."
    fallocate -l "${TAILLE_GO}G" "$IMAGE"
    chmod 600 "$IMAGE"
  fi
  if [[ $(blkid -p -s TYPE -o value "$IMAGE" 2>/dev/null || true) != xfs ]]; then
    echo "Formatage XFS..."
    mkfs.xfs -q -f -L bd511cluster "$IMAGE"
  fi
  if ! grep -qE "^${IMAGE}[[:space:]]" /etc/fstab; then
    cp /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d%H%M%S)"
    printf '%s\t%s\txfs\tdefaults,loop,noatime,nofail\t0\t0\n' "$IMAGE" "$POINT" >> /etc/fstab
  fi
  systemctl daemon-reload
  mount "$POINT"
fi
chmod 0755 "$POINT"

# Un répertoire par mongod (les mongos n'ont pas de données), propriété de l'uid 999, accès restreint.
awk -F'\t' 'NR > 1 && $5 == "mongod" { print $7 }' "$ARCHI" | while read -r rep; do
  install -d -m 0750 -o "$UID_MONGODB" -g "$UID_MONGODB" "$POINT/$rep"
done

# Docker ne doit pas démarrer les conteneurs si le volume n'est pas monté :
# sinon mongod initialiserait des répertoires vides sur le disque système.
install -d /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/bd511-volume.conf <<CONF
# BD511 : les conteneurs MongoDB ont besoin du volume de données $POINT
[Unit]
RequiresMountsFor=$POINT
CONF
systemctl daemon-reload

findmnt "$POINT"
ls -ln "$POINT"
