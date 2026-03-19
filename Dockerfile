FROM fossology/fossology:4.6.0

ADD scancode.conf.diff /usr/local/etc/fossology/mods-enabled/scancode/scancode.conf.diff
RUN cd /usr/local/etc/fossology/mods-enabled/scancode && patch -N < /usr/local/etc/fossology/mods-enabled/scancode/scancode.conf.diff
ADD scancode.conf.diff2 /usr/local/etc/fossology/mods-enabled/scancode/scancode.conf.diff2
RUN cd /usr/local/etc/fossology/mods-enabled/scancode && patch -N < /usr/local/etc/fossology/mods-enabled/scancode/scancode.conf.diff2
RUN apt update && apt install supervisor
ADD supervisor-progs.conf /etc/supervisor/conf.d/supervisor-progs.conf
ADD docker-entrypoint.sh docker-entrypoint.sh

