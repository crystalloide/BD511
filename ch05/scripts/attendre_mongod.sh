#!/usr/bin/env bash
# BD511 – TP chapitre 5 – attend que mongod réponde sur 127.0.0.1:27017 (60 s maximum)
# Usage : bash ~/tp05-securite/scripts/attendre_mongod.sh
for _ in $(seq 1 60); do
  if mongosh --quiet "mongodb://127.0.0.1:27017" --eval 'db.runCommand({ ping: 1 }).ok' > /dev/null 2>&1; then
    echo "mongod prêt."
    exit 0
  fi
  sleep 1
done
echo "ÉCHEC : mongod ne répond pas après 60 s." >&2
echo "Diagnostic : sudo systemctl status mongod --no-pager ; sudo tail -n 20 /var/log/mongodb/mongod.log" >&2
exit 1
