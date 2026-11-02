## Pour adapter le TP sur Ubuntu 22.04  / Ubuntu 24.04
```bash

cat > ~/install-mongodb-8.3.sh << 'EOF'
#!/usr/bin/env bash
# Installation MongoDB Community 8.3 – Ubuntu 22.04 (Jammy) / 24.04 (Noble)
set -euo pipefail

MONGO_VERSION="8.3"
KEY_URL="https://pgp.mongodb.com/server-8.0.asc"
KEY_URL_ALT="https://www.mongodb.org/static/pgp/server-8.0.asc"
KEYRING="/usr/share/keyrings/mongodb-server-8.0.gpg"
KEY_FPR="4B0752C1BCA238C0B4EE14DC41DE058A4E7DCA05"
LIST="/etc/apt/sources.list.d/mongodb-org-${MONGO_VERSION}.list"
CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")

# 0. Contrôle de la version d'Ubuntu
case "$CODENAME" in
  noble|jammy|focal) echo ">> Ubuntu ${CODENAME} détecté" ;;
  *) echo "ERREUR : version Ubuntu non supportée (${CODENAME})"; exit 1 ;;
esac

# 1. Prérequis
sudo apt-get update
sudo apt-get install -y gnupg curl

# 2. Clé GPG : téléchargement contrôlé, conversion, vérification de l'empreinte
curl -fsSL -o /tmp/server-8.0.asc "$KEY_URL" || curl -fsSL -o /tmp/server-8.0.asc "$KEY_URL_ALT"
grep -q 'BEGIN PGP PUBLIC KEY BLOCK' /tmp/server-8.0.asc || { echo "ERREUR : clé GPG non téléchargée"; exit 1; }
sudo gpg --batch --yes --dearmor -o "$KEYRING" /tmp/server-8.0.asc
sudo chmod 644 "$KEYRING"
gpg --show-keys --with-colons "$KEYRING" | grep -q "$KEY_FPR" || { echo "ERREUR : empreinte de clé inattendue"; exit 1; }
echo ">> Clé GPG OK"

# 3. Dépôt MongoDB (suppression des anciens fichiers MongoDB, ex. 'noble' sur une Jammy)
sudo rm -f /etc/apt/sources.list.d/mongodb-org-*.list
echo "deb [ arch=amd64,arm64 signed-by=${KEYRING} ] https://repo.mongodb.org/apt/ubuntu ${CODENAME}/mongodb-org/${MONGO_VERSION} multiverse" \
  | sudo tee "$LIST"

# 4. Installation
sudo apt-get update
sudo apt-get install -y mongodb-org

# 5. Démarrage et vérification
sudo systemctl enable --now mongod
for i in $(seq 1 30); do
  mongosh --quiet --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1 && break
  sleep 1
done
echo ">> Service mongod : $(systemctl is-active mongod)"
mongod --version | head -1
mongosh --quiet --eval 'db.runCommand({ ping: 1 })'
echo ">> Installation terminée"
EOF
bash ~/install-mongodb-8.3.sh
```
