FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    coreutils \
    default-mysql-client \
    postgresql-client \
    tzdata \
  && rm -rf /var/lib/apt/lists/* \
  && if [ ! -x /usr/bin/mysqldump ] && [ -x /usr/bin/mariadb-dump ]; then ln -s /usr/bin/mariadb-dump /usr/bin/mysqldump; fi

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["run"]
