ARG FOSSOLOGY_BASE_IMAGE=registry.devops.defra01.iris-sensing.net/it/infrastructure/container-images/fossology/fossology:latest
FROM ${FOSSOLOGY_BASE_IMAGE}

# The base runs as fossy. Package installation and template changes happen here.
USER root
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends supervisor \
 && rm -rf /var/lib/apt/lists/*

# The live configuration is a symlink into /run and is populated by the base
# entrypoint. Edit its build-time templates, preserving the ScanCode overrides.
RUN scancode_conf=/usr/local/etc/fossology.dist/mods-enabled/scancode/scancode.conf \
 && test -f "$scancode_conf" \
 && sed -i -e 's/^max = .*/max = 4/' \
           -e 's/^special\[\] =.*/special[] = NOKILL/' "$scancode_conf" \
 && grep -Fx 'max = 4' "$scancode_conf" \
 && grep -Fx 'special[] = NOKILL' "$scancode_conf"

COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY supervisor-progs.conf /etc/supervisor/conf.d/supervisor-progs.conf
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh \
 && ln -sf /usr/local/bin/docker-entrypoint.sh /fossology/docker-entrypoint.sh

# The leading empty element retains each SAPI's standard conf.d and extensions.
# A writable drop-in works for Apache and CLI without writing to /etc/php.
ENV PHP_INI_SCAN_DIR=:/run/fossology/php-conf.d

USER 10001:10001
WORKDIR /fossology
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["supervisor"]

