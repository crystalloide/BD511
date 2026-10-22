"""connexion.py - BD511 ch.3 : création du client MongoDB partagé par les scripts du TP."""
import os
import sys

from pymongo import MongoClient


def get_client() -> MongoClient:
    """Crée le client à partir de MONGODB_URI (un seul client par processus : il gère son pool de connexions)."""
    uri = os.environ.get("MONGODB_URI")
    if not uri:
        sys.exit("MONGODB_URI n'est pas définie : exécutez « source ~/bd511/ch03/python/bd511.env ».")
    # tz_aware=True : les dates lues sont des datetime avec fuseau (UTC), jamais des dates « naïves »
    return MongoClient(uri, tz_aware=True)
