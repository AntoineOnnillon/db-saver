FROM debian:bookworm-slim

ARG PG_MAJOR=17

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    coreutils \
    default-mysql-client \
    gnupg \
    tzdata \
    wget \
  && install -d /usr/share/postgresql-common/pgdg \
  && wget -qO /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
       https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
       > /etc/apt/sources.list.d/pgdg.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends "postgresql-client-${PG_MAJOR}" \
  && apt-get purge -y --auto-remove gnupg wget \
  && rm -rf /var/lib/apt/lists/* \
  && if [ ! -x /usr/bin/mysqldump ] && [ -x /usr/bin/mariadb-dump ]; then ln -s /usr/bin/mariadb-dump /usr/bin/mysqldump; fi

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["run"]
