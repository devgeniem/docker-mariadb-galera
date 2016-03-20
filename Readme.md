# MariaDB Galera Docker Container

This is default mariadb docker container configured into galera mode.

## Settings
Set `BOOTSTRAP=on` for the node which bootstraps the cluster.


## Problems
This has slight problem that when the bootstrap node wasn't last man standing other nodes won't join without manually interference:

```
WSREP: gcs/src/gcs_group.cpp:group_post_state_exchange():321: Reversing history: 6987 -> 6986, this member has applied 1 more events than the primary component.Data loss is possible. Aborting.
```

Maybe the galera state could be stored elsewhere so that last man standing could always bootstrap the cluster after cluster failure.

## Building
```
$ docker build -t onnimonni/mariadb-galera .
```

## Running
```
$ docker run --name some-mariadb -e MYSQL_ROOT_PASSWORD=my-secret-pw -d onnimonni/mariadb-galera
```

## Debugging
```
$ docker exec -it some-mariadb bash
$ root@1698dcb92c7b mysql --password=$MYSQL_ROOT_PASSWORD
```

## LICENSE
MIT
