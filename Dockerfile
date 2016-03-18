# Update version number depending on stable release
FROM mariadb:10.1.12
MAINTAINER Onni Hakala - Geniem Oy <onni.hakala@geniem.com>

ENV TERM="xterm"

RUN apt-get install galera-3

ADD root-files /
