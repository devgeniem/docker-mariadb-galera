# Update version number depending on mariadb stable release
FROM mariadb:10.1.13
MAINTAINER Onni Hakala - Geniem Oy <onni.hakala@geniem.com>

# Install percona xtrabackup
RUN apt-get update && \
    apt-get install xtrabackup && \
    rm -rf /var/cache/apk/*

ADD root-files /

ENTRYPOINT ["/docker-entrypoint.sh"]

# Expose mysql port and replication ports
EXPOSE 3306 4444 4567 4568

ENV TERM="xterm"

CMD ["mysqld"]
