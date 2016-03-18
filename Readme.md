# MariaDB Galera Docker Container

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
