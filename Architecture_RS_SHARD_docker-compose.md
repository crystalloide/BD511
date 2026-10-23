host	port d'écoute	fonction	groupe	service	paramètre	répertoire

192.168.100.111	27011	primary	RS1	mongod	 --shardsvr	rs11

192.168.100.112	27012	secondary	RS1	mongod	 --shardsvr	rs12

192.168.100.113	27013	arbitre	RS1	mongod	 --shardsvr	rs1arb

192.168.100.121	27021	primary	RS2	mongod	 --shardsvr	rs21

192.168.100.122	27022	secondary	RS2	mongod	 --shardsvr	rs22

192.168.100.123	27023	arbitre	RS2	mongod	 --shardsvr	rs2arb

192.168.100.131	27031	primary	RS3	mongod	 --shardsvr	rs31

192.168.100.132	27032	secondary	RS3	mongod	 --shardsvr	rs32

192.168.100.133	27033	arbitre	RS3	mongod	 --shardsvr	rs3arb

192.168.100.101	27041	serveur config	RSCFG	mongod	 --configsvr	config1

192.168.100.102	27042	serveur config	RSCFG	mongod	 --configsvr	config2

192.168.100.103	27043	serveur config	RSCFG	mongod	 --configsvr	config3

192.168.100.141	27017	routeur requête		mongos		mongos1

192.168.100.142	27018	optionnel		mongos		mongos2
