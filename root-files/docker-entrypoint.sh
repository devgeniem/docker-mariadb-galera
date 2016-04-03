#!/bin/bash
set -eo pipefail

# Custom helpers
function get_ip() {
  ip addr show eth0 | grep "inet\b" | awk '{print $2}' | cut -d/ -f1
}

# Check if remote mysql accepts connections
# @param $1 - remote mysql ip
# @return 0 | 1 - Returns boolean
function check_mysql_up() {
  local host=$1
  mysqladmin -h$host --password=$MYSQL_ROOT_PASSWORD ping > /dev/null 2>&1
  return $?
}

function init_database() {
  # Get config
  local DATADIR="$(mysqld --verbose --help --log-bin-index=`mktemp -u` 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"
  if [ ! -d "$DATADIR/mysql" ]; then
    mkdir -p "$DATADIR"
    chown -R mysql:mysql "$DATADIR"

    echo 'Initializing database'
    mysql_install_db --user=mysql --datadir="$DATADIR" --rpm
    echo 'Database initialized'
  fi
}

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
  set -- mysqld "$@"
fi

# skip setup if they want an option that stops mysqld
wantHelp=
for arg; do
  case "$arg" in
    -'?'|--help|--print-defaults|-V|--version)
      wantHelp=1
      break
      ;;
  esac
done

# Clear files which stayed because of network failure and may cause problems
if [ -f /var/mysql/lib/rsync_sst.pid ] ; then
    rm /var/mysql/lib/rsync_sst.pid
fi

# Replace galera configs if docker gave as any envs
GCONFIG=/etc/mysql/conf.d/cluster.cnf

# Set defaults if they are not set
export NODE_ADDRESS=${NODE_ADDRESS:-$(get_ip)}
export NODE_NAME=${NODE_NAME:-$(hostname)}
export CLUSTER_NAME=${CLUSTER_NAME:-Galera}

# Replace configs
sed -i "s|%%NODE_ADDRESS%%|$NODE_ADDRESS|g" $GCONFIG
sed -i "s|%%NODE_NAME%%|$NODE_NAME|g" $GCONFIG
sed -i "s|%%CLUSTER_NAME%%|$CLUSTER_NAME|g" $GCONFIG

# Replace debian.cnf
sed -i "s|^user.*|user     = root|g" /etc/mysql/debian.cnf
sed -i "s|^password.*|password = $MYSQL_ROOT_PASSWORD|g" /etc/mysql/debian.cnf

# Check if this node has any open remote mysql servers to connect
if [ -z "$CLUSTER_MEMBERS" ]; then
  sed -i "s|%%CLUSTER_MEMBERS%%|$NODE_NAME|g" $GCONFIG
else

  # If this node knows any others add them to the config
  sed -i "s|%%CLUSTER_MEMBERS%%|$CLUSTER_MEMBERS|g" $GCONFIG

  # Try to connect to any open node
  while : ; do
    echo "---> Checking if anybody else is alive..."
    # Test connections to each node
    for ip in $(echo $CLUSTER_MEMBERS | sed "s/,/ /g")
    do
        # call your procedure/other scripts here below
        if check_mysql_up $ip; then
          # Start joiner process
          init_database
          exec "$@"
          return $?
        else
          echo "---> ERROR: $ip is not up..."
        fi
    done

    # If this is the bootstrap node break here
    [[ "$BOOTSTRAP" == "on" ]] && break

    # Otherwise wait for the bootstrapping node
    sleep 5
  done
fi

##
# This is the basic mariadb startup script
##

echo "---> Bootstrapping the $CLUSTER_NAME cluster..."

# Run pre-mysqld scripts
if [ "$1" = 'mysqld' -a -z "$wantHelp" ]; then
  # Get config
  DATADIR="$("$@" --verbose --help --log-bin-index=`mktemp -u` 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"

  if [ ! -d "$DATADIR/mysql" ]; then
    if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
      echo >&2 'error: database is uninitialized and password option is not specified '
      echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
      exit 1
    fi

    mkdir -p "$DATADIR"
    chown -R mysql:mysql "$DATADIR"

    echo 'Initializing database'
    mysql_install_db --user=mysql --datadir="$DATADIR" --rpm
    echo 'Database initialized'

    # Start mysqld process
    #Allow this to be run as normal mariadb too
    if [ "$BOOTSTRAP" = "on" ]; then
      "$@" --wsrep-new-cluster --skip-networking &
    else
      "$@" --skip-networking &
    fi
    pid="$!"

    mysql=( mysql --protocol=socket -uroot )

    # TODO: Everything works for a moment with:
    # docker run --name some-mariadb -e MYSQL_ROOT_PASSWORD=my-secret-pw -d onnimonni/mariadb-galera mysqld --wsrep-new-cluster
    # docker run --name some-mariadb2 -e MYSQL_ROOT_PASSWORD=my-secret-pw -e CLUSTER_MEMBERS=172.17.0.12 -d onnimonni/mariadb-galera mysqld --wsrep_cluster_address=gcomm://172.17.0.12

    # Then joining nodes will stop because of for loop.
    # Only boostrapping node should continue after this:
    # I think i will use consul to orchestrate which node should bootstrap and which should join

    for i in {30..0}; do
      if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
        break
      fi
      echo 'MySQL init process in progress...'
      sleep 1
    done
    if [ "$i" = 0 ]; then
      echo >&2 'MySQL init process failed.'
      exit 1
    fi

    if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
      # sed is for https://bugs.mysql.com/bug.php?id=20545
      mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
    fi

    if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
      MYSQL_ROOT_PASSWORD="$(pwgen -1 32)"
      echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
    fi
    "${mysql[@]}" <<-EOSQL
      -- What's done in this file shouldn't be replicated
      --  or products like mysql-fabric won't work
      SET @@SESSION.SQL_LOG_BIN=0;
      DELETE FROM mysql.user ;
      CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
      GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
      DROP DATABASE IF EXISTS test ;
      FLUSH PRIVILEGES ;
EOSQL

    if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
      mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
    fi

    # Create replicating user for xtrabackup
    if [ "$REPL_PASSWORD" ]; then

      export REPL_USER=${REPL_USER:-replicator} # Set default if $REPL_USER is not set

      echo "CREATE USER '$REPL_USER'@'%' IDENTIFIED BY '$REPL_PASSWORD'; \
            GRANT ALL ON *.* TO '$REPL_USER'@'%';" | "${mysql[@]}"

    fi

    if [ "$MYSQL_DATABASE" ]; then
      echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
      mysql+=( "$MYSQL_DATABASE" )
    fi

    if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
      echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" | "${mysql[@]}"

      if [ "$MYSQL_DATABASE" ]; then
        echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" | "${mysql[@]}"
      fi

      echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
    fi

    echo
    for f in /docker-entrypoint-initdb.d/*; do
      case "$f" in
        *.sh)     echo "$0: running $f"; . "$f" ;;
        *.sql)    echo "$0: running $f"; "${mysql[@]}" < "$f"; echo ;;
        *.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
        *)        echo "$0: ignoring $f" ;;
      esac
      echo
    done

    if ! kill -s TERM "$pid" || ! wait "$pid"; then
      echo >&2 'MySQL init process failed.'
      exit 1
    fi

    echo
    echo 'MySQL init process done. Ready for start up.'
    echo
  fi

  chown -R mysql:mysql "$DATADIR"
  echo "Starting mysql process..."
fi

# Allow this to be run as normal mariadb too
if [ "$BOOTSTRAP" = "on" ]; then
  exec "$@" "--wsrep-new-cluster"
else
  exec "$@"
fi
