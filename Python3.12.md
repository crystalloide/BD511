Si la VM est en Ubuntu 22.04, qui fournit Python 3.10, 
le TP a été écrit pour 24.04 (Python 3.12 par défaut, dépôt MongoDB noble). 

Sur une VM en Ubuntu 22.4, installer un Python récent à côté de celui du système et travailler dans un environnement virtuel.

1. Installer Python 3.12 (dépôt deadsnakes)

```bash
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt-get update
sudo apt-get install -y python3.12 python3.12-venv
```

2. Créer et activer un venv

```bash
python3.12 -m venv ~/BD511/.venv
source ~/BD511/.venv/bin/activate
python3 --version        # doit afficher 3.12.x
pip install --upgrade pip
```

3. Relancer le script de vérification

Relancer dans ce même terminal, venv activé, pour que python3 désigne bien la 3.12.

À ne pas faire : remplacer /usr/bin/python3 par la 3.12, que ce soit avec update-alternatives ou un lien symbolique. 
Plusieurs outils système d’Ubuntu 22.04, dont certains liés à apt, dépendent de la 3.10 et cesseraient de fonctionner.
