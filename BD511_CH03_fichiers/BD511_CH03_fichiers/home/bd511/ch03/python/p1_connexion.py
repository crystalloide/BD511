"""p1_connexion.py - BD511 ch.3 : test de connexion avec PyMongo."""
import sys

import pymongo
from pymongo.errors import PyMongoError

from connexion import get_client

with get_client() as client:
    try:
        client.admin.command("ping")
    except PyMongoError as erreur:
        sys.exit(f"Serveur injoignable : {erreur}")

    options = client.options
    print("PyMongo                :", pymongo.__version__)
    print("Serveur MongoDB        :", client.server_info()["version"])
    print("Bases                  :", ", ".join(client.list_database_names()))
    print("Pool de connexions max :", options.pool_options.max_pool_size)
    print("Délai des opérations   :", options.timeout, "s")
    print("Write concern          :", client.write_concern.document)

    db = client["bd511"]
    for nom in sorted(db.list_collection_names()):
        print(f"bd511.{nom:<16}: {db[nom].count_documents({})} documents")
